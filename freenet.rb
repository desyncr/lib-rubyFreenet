require 'freenet/exceptions'
require 'freenet/uri'
require 'freenet/fcp'

if $0 == __FILE__
  client = Freenet::FCP::Client.new
  index_url = "USK@PFeLTa1si2Ml5sDeUy7eDhPso6TPdmw-2gWfQ4Jg02w,3ocfrqgUMVWA2PeorZx40TW0c-FiIOL-TWKQHoDbVdE,AQABAAE/Index/34/"
  #puts client.get(index_url).data
  thread = Thread.new do
    client.get(index_url, true) do |status, message, response|
      case status
      when :finished
        puts "Request finished"
        puts response.data
      when :pending
      end
    end
  end
  thread.join
  client.disconnect
end