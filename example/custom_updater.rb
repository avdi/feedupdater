class CustomUpdater < FeedTools::FeedUpdater
  on_begin do
#     self.feed_href_list = [
#       "http://www.gigaom.com/feed/rss2/",
#       "http://feeds.feedburner.com/ManeuverMarketingCommunique",
#       "http://www.afp.com/english/rss/stories.xml",
#       "http://www.railheaddesign.com/rss/railhead.xml",
#       "http://www.nateanddi.com/rssfeed.xml"
#     ]
  end
  
  on_update do |feed, seconds|
    self.logger.info("Loaded '#{feed.href}'.")
    self.logger.info("=> Updated (#{feed.title}) in #{seconds} seconds.")
  end
  
  on_error do |href, error|
    self.logger.info("Error updating '#{href}':")
    self.logger.info(error)
  end

  on_complete do |updated_feed_hrefs|
  end
end