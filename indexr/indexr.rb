$:.push('../')
require 'freenet_client'
require 'erb'
require 'rubyful_soup'

# Example for FreenetR useage.
#
# This is a very simple freenet spider. It starts at a URI, follows all HTML links if they have a valid Freenet
# URI and puts them on a page. Basic categorization is done based on tag density and META keywords and an erb file
# is called to produce HTML output.
#
# This isn't a pretty example, but it works.
class IndexR
  # The depth to follow links to. Remember that the number of pages tends to increase rapidly
  # with a single depth increase
  RECURSE_DEPTH=5
  
  # An array of URIs to start spidering with
  START_PAGES = [
  "USK@PFeLTa1si2Ml5sDeUy7eDhPso6TPdmw-2gWfQ4Jg02w,3ocfrqgUMVWA2PeorZx40TW0c-FiIOL-TWKQHoDbVdE,AQABAAE/Index/34/"
  ]
  
  # Start spidering
  def initialize
    @process_threads = [] # all the processing threads, so we can cull them
    @waiting_urls = [] # The URIs waiting for response from Freenet
    @all_uris = [] # All URIs checked, to prevent doubleups
    @pages = {} # All page objects created
    @pages_semaphore = Mutex.new # Used to sync operations on @pages
    @mutex = Mutex.new # Used for any other member variables
    @mutex.lock
    # Log in to the client. We specify a static client name so only one instance can run
    # at a time.
    @client = Freenet::FCP::Client.new('IndexR')
    
    # Start mining the pages
    START_PAGES.each do |page|
      mine_page(Freenet::URI.new(page))
    end
    @mutex.unlock
    
    puts 'Starting processing'
    # This loop culls threads and checks if processing is complete
    loop do
      @mutex.lock
      @process_threads.each do |thread|
        puts "Thread count: #{@process_threads.length}"
        begin
          if thread.join(0.5)
            @process_threads.delete_if {|x| x==thread}
          end
        rescue Exception => e # Make sure a mistake in a thread doesn't kill everything... Could be done better
          puts "Exception in processing thread: #{e.to_s}"
          puts e.backtrace.join("\n")
          @process_threads.delete_if {|x| x==thread}
        end
      end
      puts "URIs waiting: #{@waiting_urls.length}, Total Scanned: #{@all_uris.length}"
      puts @waiting_urls.join("\n") if @waiting_urls.size < 3
      @mutex.unlock
      sleep(5)
      # If there are no waiting URLs and no processing threads we're done.
      # We should lock here...
      break if @process_threads.empty? and @waiting_urls.empty?
    end
    puts 'All processing done'
    create_index_page # create the page
    puts 'Disconnecting'
    @client.disconnect # disconnect
  end
  
  # Mine a page. uri is a Freenet::URI. depth is managed by mine_page to ensure
  # that we don't exceed RECURSE_DEPTH
  def mine_page(uri, depth=0)
    # Filter out pages we don't want (images, binaries)
    case uri.path
    when /\.html$/
    when /\.htm$/
    when /\/$/
    when ''
    when nil
    else
      puts "Ignoring path '#{uri.path.to_s}'"
      return
    end
    
    # Check that we don't duplicate the page request
    uri_queued = false
    @pages_semaphore.synchronize do
      uri_queued = true if @all_uris.include? uri.uri
      @waiting_urls << uri.uri unless uri_queued
      @all_uris << uri.uri unless uri_queued
    end
    # If it's already being checked we stop
    if uri_queued
      return
    end
    
    # Get the page
    @client.get(uri.uri, true, "Persistence"=>'connection','PriorityClass'=>3) do |status, message, response|
      @mutex.lock # Lock the object
      case status
      when :finished # If we have the data and it's text/html we process it.
        page = response.data
        if message.content_type =~ /^text\/html/
          thread = Thread.new do # Do it in a new thread, just because.
            begin
              process_page(uri, response.data, depth)
            rescue Exception => e
              puts "#{e.to_s}"
            end
          end
          @process_threads << thread
        else
          puts "Unknown content type: #{message.content_type} URI:#{uri.uri}"
        end
      when :failed # If it failed then we ditch the URI
        @pages_semaphore.synchronize do
          @waiting_urls.delete_if {|u| u == uri.uri}
        end
      when :redirect # In case of redirect we issue a new request for it.
        @pages_semaphore.synchronize do
          @waiting_urls.delete_if {|u| u == uri.uri}
        end
        @mutex.unlock
        mine_page(Freenet::URI.new(response.items['RedirectURI']), depth)
        @mutex.lock
      when :retrying
        puts "Got retry notification"
      when :pending
      end
      @mutex.unlock
    end
  end
  
  # Pull links out of a page and mine them deeper
  def process_page(uri, page, depth)
    begin
      page = FreenetPage.new(uri.uri, page)
      page.links.each do |link|
        # We only want to mine freenet pages, not anything that operates directly on FProxy, like
        # add bookmark links
        begin
          case link
          when /\/?([KSU]S|CH)K/
            mine_page(Freenet::URI.new(link),depth+1) unless depth == RECURSE_DEPTH
          when /^\//
          when /^\?/
          else
            mine_page(Freenet::URI.new(link),depth+1) unless depth == RECURSE_DEPTH
          end
        rescue Freenet::URIError => e
          puts "Bad URI: #{link}"
        end
      end
      @pages_semaphore.synchronize do
        @pages[uri.uri] = page
      end
    rescue Exception => e # This is normally a bad URI or something that's not HTML
      puts "Processing Exception: #{e.to_s}\n#{e.backtrace.join("\n")}"
    ensure # Make sure we delete the URI from the waiting list no matter what
      @pages_semaphore.synchronize do
        @waiting_urls.delete_if {|u| u == uri.uri}
      end
    end
  end
  
  # Create index page. Sort pages and send to the erb template
  def create_index_page
    template = nil
    File.open('index.rhtml') do |f|
      template = ERB.new(f.read, nil, '-')
    end
    @pages_semaphore.synchronize do
      @pages.delete_if {|uri, page| page.nil? }
      START_PAGES.each do |uri|
        @pages[uri].run_rank(5, @pages)
      end
      @sorted_pages = @pages.values.sort
      File.open('index.html', 'w') do |f|
        f.write(template.result(binding))
      end
    end
  end
end


# A page on Freenet, uses beautifulsoup to parse non-XML-compliant HTML files,
class FreenetPage
  attr_accessor :url, :title, :meta, :uri, :links, :category
  attr_reader :rank
  def initialize(url, data)
    @uri = Freenet::URI.new(url)
    @rank = 0
    @data = data
    @links = []
    @meta = {}
    @category = :unknown
    @page = BeautifulSoup.new(data)
    raise FreenetPageError.new if @page.nil?
    @page.find_all('a').each do |link|
      begin
        href = link['href'] or next
        @links << uri.merge(href)
      rescue Freenet::URIError => e
        puts 'Invalid URI'
      end
    end
    
    @title = @page.html.head.title.string || "No Title"
    
    @page.find_all('meta').each do |meta|
      if meta['name'] and meta['content']
        @meta[meta['name'].downcase] = meta['content']
      end
    end
  rescue Exception => e # Raise this if we can't make the page, for whatever reason.
    raise FreenetPageError.new
  end
  
  def run_rank(rank, all_pages)
    @rank += rank
    pass_rank = rank.to_f/@page.find_all('a').size
    return if pass_rank < 0.01
    @page.find_all('a').each do |link|
      begin
        href = link['href'] or next
        if uri = @uri.merge(href) and uri != @uri.uri and all_pages[uri]
          all_pages[uri].run_rank(pass_rank, all_pages)
        end
      rescue Freenet::URIError=>e
      end
    end
  end
  
  # Magic voodoo of half-baked ideas. It's supposed to sort pages in to categories.
  def categorize
    links = @page.find_all('a')
    imgs = @page.find_all('img')
    total_count = 0
    tag_count = @page.find_all {|tag| total_count += 1}
    if imgs.size/total_count.to_f > 0.3 or (links.size/imgs.size) > 0.8
      :image_gallery
    elsif links.size/total_count.to_f > 0.3
      :link_directory
    else
      if @meta['keywords']
        keywords = @meta['keywords'].split(',')
        keywords.collect! {|kw| kw.downcase}
        if keywords.include? 'index'
          :index_site
        else
          :unknown
        end
      else
        :unknown
      end
    end
  end
  
  def <=>(other)
    return -1 if other.nil?
    if @category == other.category
      @title <=> other.title
    else
      @category.to_s <=> other.category.to_s
    end
  end
end

# Generic FreenetPageError
class FreenetPageError < Exception
end

if $0 == __FILE__
  i = IndexR.new
  i.create_index_page
end