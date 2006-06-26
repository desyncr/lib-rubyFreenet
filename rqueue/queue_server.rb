require 'thread'
require 'drb'

# DRuby server
class QueueServer
  attr_accessor :temp_dir
  
  def self.start_server(bind_to)
    server = QueueServer.new
    DRb.start_service("druby://#{bind_to}", server)
    server
  end
  
  def initialize
    @client = Freenet::FCP::Client.new
    @client.watch_global
    @status = {}
    @messages = {}
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
        @messages[uri] = @client.get(uri, false, 'Persistence'=>'reboot',
            'Global'=>'true', 'Verbosity'=>'1', 'MaxRetries'=>'30') do |status, request, response|
          case status
          when :failed
            @status_mutex.lock
            @status[request.items['URI']][:status] = 'Failed'
            @client.remove_request(request)
            p response.items
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
            data[:progress] = ((response.items['Suceeded'].to_f/response.items['Required'].to_f)*100).ceil
            @status_mutex.unlock
          when :found
            @status_mutex.lock
            @status[request.items['URI']][:status] = 'Data Found'
            @status_mutex.unlock
          when :finished
            @status_mutex.lock
            @status[request.items['URI']][:status] = 'Finished'
            @status[request.items['URI']][:progress] = 100
            if @temp_dir
              File.open(File.join(@temp_dir, @status[request.items['URI']][:filename]), 'w') do |file|
                file.write(response.data)
              end
            else
              @status[request.items['URI']][:data] = response.data
            end
            @status[request.items['URI']][:content_type] = response.items['Metadata.ContentType']
            @status_mutex.unlock
            @client.remove_request(request)
          end
        end
        queued << uri
        @status_mutex.lock
        filename = new_uri.path.gsub('/','_')
        @status[uri] = {:uri=>uri, :status=>:started, :data=>nil, :total=>0, :required=>0, :failed=>0, :fatally_failed=>0,
                        :succeeded=>0, :finalised=>false, :progress=>0, :content_type=>'', :filename=>filename, :added=>Time.now}
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
    if @messages[uri]
      @client.remove_request(@messages[uri]) if @status[uri][:status] != 'Finished'
      if @temp_dir
        status = @status[uri]
        begin
          File.delete(File.join(@temp_dir, status[:filename]))
        rescue
        end
      end
      @status.delete(uri)
      @messages.delete(uri)
    end
    @status_mutex.unlock
    true
  end
  
  def details_for(uri)
    @status_mutex.lock
    details = nil
    details = @status[uri].dup unless @status[uri].nil?
    @status_mutex.unlock
    details
  end
  
  def data_for(uri)
    data = nil
    @status_mutex.lock
    if @status[uri]
      if @temp_dir
        File.open(File.join(@temp_dir, @status[uri][:filename])) do |file|
          data = file.read
        end
      else
        data = @status[uri].data
      end
    end
    @status_mutex.unlock
    data
  end
end