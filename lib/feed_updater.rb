#--
# Copyright (c) 2005 Robert Aman
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#++

require 'feed_updater/version'

# :stopdoc:
# ROFLCOPTERS?
# This mainly exists because of the approximately 1 billion different
# ways to deploy this script.
if !defined?(FileStalker)
  class FileStalker
    def self.hunt(paths)
      for path in paths
        if File.exists?(File.expand_path(path))
          return File.expand_path(path)
        elsif File.exists?(File.expand_path(
            File.dirname(__FILE__) + path))
          return File.expand_path(File.dirname(__FILE__) + path)
        elsif File.exists?(File.expand_path(
            File.dirname(__FILE__) + "/" + path))
          return File.expand_path(File.dirname(__FILE__) + "/" + path)
        end
      end
      return nil
    end
  end
end
# :startdoc:

$:.unshift(File.dirname(__FILE__))
$:.unshift(File.dirname(__FILE__) + "/feed_updater/vendor")

# Make it so Rubygems can find the executable
$:.unshift(File.expand_path(File.dirname(__FILE__) + "/../bin"))

require 'rubygems'

if !defined?(Daemons)
  begin
    require_gem('daemons', '>= 0.4.4')
  rescue LoadError
    require 'daemons'
  end
end

if !defined?(FeedTools::FEED_TOOLS_VERSION)
  begin
    if File.exists?(File.expand_path(
        File.dirname(__FILE__) + "/../../feedtools/lib"))
      $:.unshift(File.expand_path(
        File.dirname(__FILE__) + "/../../feedtools/lib"))
      require("feed_tools")
    else
      require_gem('feedtools', '>= 0.2.23')
    end
  rescue LoadError
    require 'feed_tools'
  end
end

require 'benchmark'
require 'thread'
require 'logger'

class FeedUpdaterLogger < Logger
  attr_accessor :prefix
  
  alias_method :old_log, :log
  def log(level, message)
    if defined?(@prefix) && @prefix != nil
      self.old_log(level, "#{self.prefix}#{message}")
    else
      self.old_log(level, message)
    end
  end

  def debug(message)
    self.log(0, message)
  end

  def info(message)
    self.log(1, message)
  end

  def warn(message)
    self.log(2, message)
  end

  def error(message)
    self.log(3, message)
  end

  def fatal(message)
    self.log(4, message)
  end
end

module FeedTools
  # A simple daemon for scheduled updating of feeds.
  class FeedUpdater
    # Declares an on_begin event.  The given block will be called before the
    # update sequence runs to allow for any setup required.  The block is
    # not passed any arguments.
    def self.on_begin(&block)
      raise "No block supplied for on_begin." if block.nil?
      @@on_begin = block
    end

    # Declares an on_update event.  The given block will be called after
    # every feed update.  The block is passed the feed object that was loaded
    # and the time it took in seconds to successfully load it.
    def self.on_update(&block)
      raise "No block supplied for on_update." if block.nil?
      @@on_update = block
    end

    # Declares an on_error event.  The given block will be called after
    # an error occurs during a feed update.  The block is passed the href of
    # the feed that errored out, and the exception object that was raised.
    def self.on_error(&block)
      raise "No block supplied for on_error." if block.nil?
      @@on_error = block
    end

    # Declares an on_complete event.  The given block will be called after
    # all feeds have been updated.  The block is passed a list of feeds that
    # FeedUpdater attempted to update.
    def self.on_complete(&block)
      raise "No block supplied for on_complete." if block.nil?
      @@on_complete = block
    end

    # Returns the initial directory that the daemon was started from.
    def initial_directory()
      @initial_directory = nil if !defined?(@initial_directory)
      return @initial_directory
    end
    
    # Returns the directory where the pid files are stored.
    def pid_file_dir()
      @pid_file_dir = nil if !defined?(@pid_file_dir)
      return @pid_file_dir
    end
    
    # Sets the directory where the pid files are stored.
    def pid_file_dir=(new_pid_file_dir)
      @pid_file_dir = new_pid_file_dir
    end
    
    # Returns the directory where the log files are stored.
    def log_file_dir()
      @log_file_dir = nil if !defined?(@log_file_dir)
      return @log_file_dir
    end
    
    # Sets the directory where the log files are stored.
    def log_file_dir=(new_log_file_dir)
      @log_file_dir = new_log_file_dir
    end
    
    # Returns the path to the log file.
    def log_file()
      if !defined?(@log_file) || @log_file.nil?
        if self.log_file_dir.nil?
          @log_file = File.expand_path("./feed_updater.log")
        else
          @log_file = File.expand_path(
            self.log_file_dir + "/feed_updater.log")
        end
      end
      return @log_file
    end
    
    # Returns the logger object.
    def logger()
      if !defined?(@logger) || @logger.nil?
        @logger = FeedUpdaterLogger.new(self.log_file)
        @logger.level = self.updater_options[:log_level]
        @logger.datetime_format = nil
        @logger.progname = nil
        @logger.prefix = "FeedUpdater".ljust(20)
      end
      return @logger
    end
        
    # Restarts the logger object.  This needs to be done after the program
    # forks.
    def restart_logger()
      begin
        self.logger.close()
      rescue IOError
      end
      @logger = FeedUpdaterLogger.new(self.log_file)
      @logger.level = self.updater_options[:log_level]
      @logger.datetime_format = nil
      @logger.progname = nil
      @logger.prefix = "FeedUpdater".ljust(20)
    end
    
    # Returns a list of feeds to be updated.
    def feed_href_list()
      if !defined?(@feed_href_list) || @feed_href_list.nil?
        @feed_href_list_override = false
        if self.updater_options.nil?
          @feed_href_list = nil
        elsif self.updater_options[:feed_href_list].kind_of?(Array)
          @feed_href_list = self.updater_options[:feed_href_list]
        else
          @feed_href_list = nil
        end
      end
      return @feed_href_list
    end
    
    # Sets a list of feeds to be updated.
    def feed_href_list=(new_feed_href_list)
      @feed_href_list_override = true
      @feed_href_list = new_feed_href_list
    end
    
    # Returns either :running or :stopped depending on the daemon's current
    # status.
    def status()
      @status = :stopped if @status.nil?
      return @status
    end
    
    # Returns a hash of the currently set updater options.
    def updater_options()
      if !defined?(@updater_options) || @updater_options.nil?
        @updater_options = {
          :start_delay => true,
          :threads => 1,
          :sleep_time => 60,
          :log_level => 0
        }
      end
      return @updater_options
    end
    
    # Returns a hash of the currently set daemon options.
    def daemon_options()
      if !defined?(@daemon_options) || @daemon_options.nil?
        @daemon_options = {
          :app_name => "feed_updater_daemon",
          :dir_mode => :normal,
          :dir => self.pid_file_dir,
          :backtrace => true,
          :ontop => false
        }
      end
      @daemon_options[:dir] = self.pid_file_dir
      return @daemon_options
    end
    
    # Returns a reference to the daemon application.
    def application()
      @application = nil if !defined?(@application)
      return @application
    end
    
    # Returns the process id of the daemon.  This should return nil if the
    # daemon is not running.
    def pid()
      if File.exists?(File.expand_path(pid_file_dir + "/feed_updater.pid"))
        begin
          pid_file = File.open(
            File.expand_path(pid_file_dir + "/feed_updater.pid"), "r")
          return pid_file.read.to_s.strip.to_i
        rescue Exception
          return nil
        end
      else
        return nil if self.application.nil?
        begin
          return self.application.pid.pid
        rescue Exception
          return nil
        end
      end
    end
    
    def cloaker(&blk) #:nodoc:
      (class << self; self; end).class_eval do
        define_method(:cloaker_, &blk)
        meth = instance_method(:cloaker_)
        remove_method(:cloaker_)
        meth
      end
    end
    protected :cloaker
    
    # Starts the daemon.
    def start()
      self.logger.prefix = "FeedUpdater".ljust(20)
      if !defined?(@@on_update) || @@on_update.nil?
        raise "No on_update handler block given."
      end
      if self.status == :running || self.pid != nil
        puts "FeedUpdater is already running."
        return self.pid
      end
      if defined?(ActiveRecord)
        ActiveRecord::Base.allow_concurrency = true
      end

      @initial_directory = File.expand_path(".")

      if @application.nil?
        self.logger()
        feed_update_proc = lambda do
          # Reestablish correct location
          Dir.chdir(File.expand_path(self.initial_directory))

          sleep(1)

          self.restart_logger()
          self.logger.info("Using environment: #{FEED_TOOLS_ENV}")
          
          if FeedTools.configurations[:feed_cache].nil?
            FeedTools.configurations[:feed_cache] =
              "FeedTools::DatabaseFeedCache"
          end

          if !FeedTools.feed_cache.connected?
            FeedTools.configurations[:feed_cache] =
              "FeedTools::DatabaseFeedCache"
            FeedTools.feed_cache.initialize_cache()
            begin
              ActiveRecord::Base.default_timezone = :utc
              ActiveRecord::Base.connection
            rescue Exception
              config_path = FileStalker.hunt([
                "./config/database.yml",
                "../config/database.yml",
                "../../config/database.yml",
                "./database.yml",
                "../database.yml",
                "../../database.yml"
              ])
              if config_path != nil
                require 'yaml'
                config_hash = File.open(config_path) do |file|
                  config_hash = YAML.load(file.read)
                  unless config_hash[FEED_TOOLS_ENV].nil?
                    config_hash = config_hash[FEED_TOOLS_ENV]
                  end
                  config_hash
                end
                self.logger.info(
                  "Attempting to manually load the database " +
                  "connection described in:")
                self.logger.info(config_path)
                begin
                  ActiveRecord::Base.configurations = config_hash
                  ActiveRecord::Base.establish_connection(config_hash)
                  ActiveRecord::Base.connection
                rescue Exception => error
                  self.logger.fatal(
                    "Error initializing database:")
                  self.logger.fatal(error)
                  exit
                end
              else
                self.logger.fatal(
                  "The database.yml file does not appear " +
                  "to exist.")
                exit
              end
            end
          end
          if !FeedTools.feed_cache.connected?
            self.logger.fatal("Not connected to the feed cache.")
            if FeedTools.feed_cache.respond_to?(:table_exists?)
              if !FeedTools.feed_cache.table_exists?
                self.logger.fatal(
                  "The FeedTools cache table is missing.")
              end
            end
            exit
          end
          
          # A random start delay is introduced so that we don't have multiple
          # feed updater daemons getting kicked off at the same time by
          # multiple users.
          if self.updater_options[:start_delay]
            delay = (rand(45) + 15)
            self.logger.info("Startup delay set for #{delay} minutes.")
            sleep(delay.minutes)
          end
          
          # The main feed update loop.
          loop do
            result = nil
            sleepy_time = self.updater_options[:sleep_time].to_i.minutes
            begin
              result = Benchmark.measure do
                self.update_feeds()
              end
              self.logger.info(
                "#{@feed_href_list.size} feed(s) updated " +
                "in #{result.real.round} seconds.")
              sleepy_time =
                (self.updater_options[:sleep_time].to_i.minutes -
                  result.real.round)
            rescue Exception => error
              self.logger.error("Feed update sequence errored out.")
              self.logger.error(error.class.name + ": " + error.message)
              self.logger.error("\n" + error.backtrace.join("\n").to_s)
            end

            @feed_href_list = nil
            @feed_href_list_override = false
            ObjectSpace.garbage_collect()
            if sleepy_time > 0
              self.logger.info(
                "Sleeping for #{(sleepy_time / 1.minute.to_f).round} " +
                "minutes...")
              sleep(sleepy_time)
            else
              self.logger.info(
                "Update took more than " +
                "#{self.updater_options[:sleep_time].to_i} minutes, " +
                "restarting immediately.")
            end
          end
        end
        options = self.daemon_options.merge({
          :proc => feed_update_proc,
          :mode => :proc
        })
        @application = Daemons::ApplicationGroup.new(
          'feed_updater', options).new_application(options)
        @application.start()
      else
        @application.start()
      end
      self.logger.prefix = nil
      self.logger.level = 0
      self.logger.info("-" * 79)
      self.logger.info("Daemon started, " +
        "FeedUpdater #{FeedTools::FEED_UPDATER_VERSION::STRING} / " +
        "FeedTools #{FeedTools::FEED_TOOLS_VERSION::STRING}")
      self.logger.info(" @ #{Time.now.utc.to_s}")
      self.logger.info("-" * 79)
      self.logger.level = self.updater_options[:log_level]
      self.logger.prefix = "FeedUpdater".ljust(20)
      @status = :running
      return self.pid
    end
    
    # Stops the daemon.
    def stop()
      if self.pid.nil?
        puts "FeedUpdater isn't running."
      end
      begin
        # Die.
        Process.kill('TERM', self.pid)
      rescue Exception
      end
      begin
        # No, really, I mean it.  You need to die.
        system("kill #{self.pid} 2> /dev/null")
        
        # Perhaps I wasn't clear somehow?
        system("kill -9 #{self.pid} 2> /dev/null")
      rescue Exception
      end
      begin
        # Clean the pid file up.
        if File.exists?(
            File.expand_path(self.pid_file_dir + "/feed_updater.pid"))
          File.delete(
            File.expand_path(self.pid_file_dir + "/feed_updater.pid"))
        end
      rescue Exception
      end
      self.logger.prefix = "FeedUpdater".ljust(20)
      self.logger.level = 0
      self.logger.info("Daemon stopped.")
      self.logger.level = self.updater_options[:log_level]
      @status = :stopped
      return nil if self.application.nil?
      begin
        self.application.stop()
      rescue Exception
      end
      return nil
    end
    
    # Restarts the daemon.
    def restart()
      self.stop()
      self.start()
    end
    
    def progress_precentage()
      if !defined?(@remaining_href_list) || !defined?(@feed_href_list)
        return nil
      end
      if @remaining_href_list.nil? || @feed_href_list.nil?
        return nil
      end
      if @feed_href_list == []
        return nil
      end
      return 100.0 - (100.0 *
        (@remaining_href_list.size.to_f / @feed_href_list.size.to_f))
    end
    
    # Updates all of the feeds.
    def update_feeds()
      self.logger.level = 0
      self.logger.prefix = "FeedUpdater".ljust(20)
      ObjectSpace.garbage_collect()
      if defined?(@@on_begin) && @@on_begin != nil
        self.logger.info("Running custom startup event...")
        self.cloaker(&(@@on_begin)).bind(self).call()
      end
      if defined?(@feed_href_list_override) && @feed_href_list_override
        self.logger.info("Using custom feed list...")
        self.feed_href_list()
      else
        self.logger.info("Loading default feed list...")
        begin
          expire_time = (Time.now - 1.hour).utc
          expire_time_string = sprintf('%04d-%02d-%02d %02d:%02d:%02d',
            expire_time.year, expire_time.month, expire_time.day,
            expire_time.hour, expire_time.min, expire_time.sec)
          @feed_href_list =
            FeedTools.feed_cache.connection.execute(
              "SELECT href FROM cached_feeds WHERE " +
              "last_retrieved < '#{expire_time_string}'").to_a.flatten
        rescue Exception
          self.logger.warn("Default feed list failed, using fallback.")
          @feed_href_list =
            FeedTools.feed_cache.find(:all).collect do |feed|
              feed.href
            end
          self.logger.warn(
            "Fallback succeeded. Custom feed list override recommended.")
        end
      end
      self.logger.info("Updating #{@feed_href_list.size} feed(s)...")
      self.logger.level = self.updater_options[:log_level]
      
      @threads = []
      @remaining_href_list = @feed_href_list.dup

      ObjectSpace.garbage_collect()

      begin_updating = false
      self.logger.info(
        "Starting up #{self.updater_options[:threads]} thread(s)...")
      
      mutex = Mutex.new
      for i in 0...self.updater_options[:threads]
        updater_thread = Thread.new do
          self.logger.level = self.updater_options[:log_level]
          self.logger.datetime_format = "%s"
          self.logger.progname = "FeedUpdater".ljust(20)
          
          while !Thread.current.respond_to?(:thread_id) &&
              begin_updating == false
            Thread.pass
          end
          mutex.synchronize do
            self.logger.prefix =
              "Thread #{Thread.current.thread_id} ".ljust(20)
            self.logger.info("Thread started.")
            
            begin
              FeedTools.feed_cache.initialize_cache()
              if !FeedTools.feed_cache.set_up_correctly?
                self.logger.info("Problem with cache connection...")
              end
            rescue Exception => error
              self.logger.info(error)
            end
          end
          
          ObjectSpace.garbage_collect()
          Thread.pass

          while @remaining_href_list.size > 0
            progress = nil
            mutex.synchronize do
              Thread.current.progress = self.progress_precentage()
              Thread.current.href = @remaining_href_list.shift()
              progress = sprintf("%.2f", Thread.current.progress)
            end
            begin
              begin
                Thread.current.feed = nil
                feed_load_benchmark = Benchmark.measure do
                  Thread.current.feed =
                    FeedTools::Feed.open(Thread.current.href)
                end
                Thread.pass
                if Thread.current.feed.live?
                  unless @@on_update.nil?
                    mutex.synchronize do
                      progress = sprintf("%.2f", Thread.current.progress)
                      self.logger.prefix = 
                        ("Thread #{Thread.current.thread_id} (#{progress}%)"
                          ).ljust(20)
                      self.cloaker(&(@@on_update)).bind(self).call(
                        Thread.current.feed, feed_load_benchmark.real)
                    end
                  end
                else
                  mutex.synchronize do
                    progress = sprintf("%.2f", Thread.current.progress)
                    self.logger.prefix = 
                      ("Thread #{Thread.current.thread_id} (#{progress}%)"
                        ).ljust(20)
                    self.logger.info(
                      "'#{Thread.current.href}' unchanged " +
                      "or unavailable, skipping.")
                  end
                end
              rescue Exception => error
                mutex.synchronize do
                  progress = sprintf("%.2f", Thread.current.progress)
                  self.logger.prefix = 
                    ("Thread #{Thread.current.thread_id} (#{progress}%)"
                      ).ljust(20)
                  if @@on_error != nil
                    self.cloaker(&(@@on_error)).bind(self).call(
                      Thread.current.href, error)
                  else
                    self.logger.error(
                      "Error updating '#{Thread.current.href}':")
                    self.logger.error(error.class.name + ": " + error.message)
                    self.logger.error(error.class.backtrace)
                  end
                end
              end
            rescue Exception => error
              mutex.synchronize do
                progress = sprintf("%.2f", Thread.current.progress)
                self.logger.prefix = ("Thread #{Thread.current.thread_id} " +
                  "(#{progress}%)"
                  ).ljust(20)
                self.logger.fatal("Critical unhandled error.")
                self.logger.fatal("Error updating '#{Thread.current.href}':")
                self.logger.fatal(error.class.name + ": " + error.message)
                self.logger.fatal(error.class.backtrace)
              end
            end
            ObjectSpace.garbage_collect()
            Thread.pass
          end          
        end
        @threads << updater_thread        
        class <<updater_thread
          attr_accessor :thread_id
          attr_accessor :progress
          attr_accessor :href
          attr_accessor :feed
        end
        updater_thread.thread_id = i
      end
      mutex.synchronize do
        self.logger.prefix = "FeedUpdater".ljust(20)
        self.logger.info(
          "#{@threads.size} thread(s) successfully started...")
        begin_updating = true
      end
      Thread.pass
      
      ObjectSpace.garbage_collect()
      Thread.pass
      for i in 0...@threads.size
        mutex.synchronize do
          self.logger.prefix = "FeedUpdater".ljust(20)
          self.logger.info(
            "Joining on thread #{@threads[i].thread_id}...")
        end
        @threads[i].join
      end
      self.logger.prefix = "FeedUpdater".ljust(20)
      ObjectSpace.garbage_collect()
      
      self.logger.progname = nil
      unless @@on_complete.nil?
        self.cloaker(&(@@on_complete)).bind(self).call(@feed_href_list)
      end
      self.logger.level = 0
      self.logger.info("Finished updating.")
      self.logger.level = self.updater_options[:log_level]
    end
  end
end