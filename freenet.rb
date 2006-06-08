$:.push(File.dirname(__FILE__))
require 'freenet/exceptions'
require 'freenet/uri'
require 'freenet/fcp'
require 'thread'

if $0 == __FILE__
  client = Freenet::FCP::Client.new
  index_url = "USK@PFeLTa1si2Ml5sDeUy7eDhPso6TPdmw-2gWfQ4Jg02w,3ocfrqgUMVWA2PeorZx40TW0c-FiIOL-TWKQHoDbVdE,AQABAAE/Index/34/"
  #puts client.get(index_url).data
  
  # As an async request is threaded off we need a mutex to prevent this from exiting early.
  # I have a feeling I'm missing something here
  semaphore = Mutex.new
  thread = Thread.new do
    semaphore.lock
    client.get(index_url, true) do |status, message, response|
      case status
      when :finished
        puts "Request finished"
        puts response.data
        semaphore.unlock
      when :pending
      end
    end
  end
  semaphore.lock
  semaphore.unlock
  thread.join
  client.disconnect
end