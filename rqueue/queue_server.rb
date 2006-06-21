require 'thread'
require 'drb'

# DRuby server
class QueueServer
  def self.start_server(bind_to)
    server = QueueServer.new
    DRb.start_service("druby://#{bind_to}", server)
    server
  end
  
  def initialize
    @client = Freenet::FCP::Client.new
    @client.watch_global
    @status = {}
    @status_mutex = Mutex.new
  end
  
  # Add URIs to the queue. Takes a variable argument list, each argument should be one URI. Returns the list
  # of URIs actually added.
  def add_uris(*args)
    queued = []
    args.each do |uri|
      begin
        next if uri == ''
        begin
          new_uri = Freenet::URI.new(uri)
        rescue
          puts 'bad URI'
          next
        end
        @client.get(uri, false, 'Persistence'=>'reboot', 'Global'=>'true', 'Verbosity'=>'1') do |status, request, response|
          case status
          when :failed
            @status_mutex.lock
            @status[request.items['URI']][:status] = 'Failed'
            @status_mutex.unlock
          when :progress
            @status_mutex.lock
            data = @status[request.items['URI']]
            data[:total] = response.items['Total']
            data[:required] = response.items['Required']
            data[:failed] = response.items['Failed']
            data[:fatally_failed] = response.items['FatallyFailed']
            data[:succeeded] = response.items['Succeeded']
            data[:finalised] = response.items['Finalized']
            data[:content_type] = response.content_type
            @status_mutex.unlock
          when :found
            @status_mutex.lock
            @status[request.items['URI']][:status] = 'Data Found'
            @status_mutex.unlock
          when :finished
            @status_mutex.lock
            @status[request.items['URI']][:status] = 'Finished'
            @status[request.items['URI']][:data] = response.data
            @status[request.items['URI']][:content_type] = response.content_type
            @status_mutex.unlock
            @client.remove_request(request)
          end
        end
        queued << uri
        @status_mutex.lock
        puts 'here'
        filename = new_uri.path.gsub('/','_')
        puts filename
        @status[uri] = {:status=>:started, :data=>nil, :total=>0, :required=>0, :failed=>0, :fatally_failed=>0,
                        :succeeded=>0, :finalised=>false, :content_type=>'', :filename=>filename}
        @status_mutex.unlock
      rescue Freenet::URIError
      end
    end
    queued
  end

  # Get a list of all URIs and their status, a hash in the format:
  #   uri => {:status=>(:started, 'Failed', 'Data Found', 'Finished), :data=>nil or file data, :total=># of split file blocks,
  #   :failed=>Blocks failed, :fatally_failed=>Blocks that cannot be retrieved, :succeeded=>Blocks downloaded,
  #   :finalised=>True if the block count is final, false if it may change, :content_type=>data's type}
  def status
    @status_mutex.lock
    s = @status.dup
    @status_mutex.unlock
    s
  end
  
  # Remove the URI from the queue.
  def remove(uri)
    @status_mutex.lock
    if @status[uri]
      @client.remove_request(@status[uri]) if @status[uri][:status] != 'Finished'
      @status.delete(uri)
    end
    @status_mutex.unlock
    true
  end
  
  def details_for(uri)
    @status_mutex.lock
    details = @status[uri].dup
    @status_mutex.unlock
    details
  end
end