require 'digest/md5'
require 'thread'

module Freenet
  module FCP
    # An FCP::Message represents a communication between the server and client. It handles basic information
    # and thread safety. When a response is received the original FCP::Message gets its response attribute
    # set to the response FCP::Message
    #
    # Please consider this object immutable. This status will be reinforced later.
    #
    # Attributes of interest
    # [load_only] Only load in to the message queue, don't actually send. Used when restoring persistent
    #             requests if a client dies
    # [content_type] The content type of the data. Set automatically on response, set manually when inserting.
    # [retries] The number of retries that have happened in case of DataNotFound. The hard limit is five at the moment.
    class Message
      attr_reader :type, :data, :items, :identifier
      attr_accessor :callback, :load_only, :response, :data_found, :content_type, :retries, :timeout, :added, :request

      # [type] The FCP message type
      # [data] Any data to send with the message
      # [items] A hash of message parameters. They vary for different messages, Timeout is a special
      #         item that sets the timeout in seconds for this message, it doesn't go to the node.
      # [callback] Callback for asynchronous messages
      def initialize(type, data = nil, items = [], callback = nil)
        @retries = 0
        @type, @data, @items = type.to_s, data, items
        @items = {} unless @items.kind_of? Hash
        @items['Identifier'] ||= "FCPMessage_#{Digest::MD5.hexdigest(Time.now.to_s)}_#{rand(100000)}"
        @identifier = @items['Identifier']
        if ['ClientHello','NodeHello'].include? @type
          @identifier = 'ClientHello'
          @items.delete('Identifier')
        end

        if @items['Timeout']
          @timeout = @items['Timeout']
          @items.delete('Timeout')
        end

        @callback = callback
        @load_only = false
        @added = Time.now
      end

      # Dispatch the callback. Private to FCP::Client
      def callback(status)
        @callback.call(status, self, @response) unless @callback.nil?
      rescue => e
        puts "ERROR: Exception in callback: #{e}\n#{e.backtrace.join("\n")}"
      end

      def callback?
        @callback.nil? == false
      end

      # Sets the reply. This is private to FCP::Client
      def continue_thread(message)
        @response = message
        @this_thread.run if @this_thread
      end

      # Used to block until the reply is received for synchronous messages. May be
      # called from any thread.
      def wait_for_response
        @this_thread = Thread.current
        Thread.stop
      end

      # Gets the status for this message. The key ones all apps need to handle are:
      # [:finished] When a request has successfully finished
      # [:redirect] The message has recieved a redirect internally
      #             This could be handled internally, I haven't decided yet.
      # [:failed] The request has fatally failed
      # [:error] An error in the FCP messages occured. This is caused by a bug in rubyFreenet
      def status
        case @type
        when 'PersistentGet'
            :get
        when 'PersistentPut'
            :put
        when 'SSKKeypair'
            :keypair
        when 'AllData'
            :finished
        when 'PersistentGet'
            :pending
        when 'SimpleProgress'
            :progress
        when 'ProtocolError'
            :failed
        when 'URIGenerated'
            :uri_generated
        when 'PutSuccessful'
            :finished
        when 'PutFailed'
            :failed
        when 'ProtocolError'
            :error
        when 'DataFound'
            :found
        when 'GetFailed'
          if items['RedirectURI']
              :redirect
          elsif items['Fatal'] == 'false'
            case items['Code']
            when '15' # Node overloaded. Wait then re-request. We can re-use the ID as GetFailed removes the ID from FRED
              if @request.retries < 5
                  :retrying
              else
                  :failed
              end
            else
                :failed
            end
          else
              :failed
          end
        end
      end

      # Write this object to an FCP stream.
      def write(stream)
        stream.write(type.strip+"\n")
        items.each do |key, value|
          stream.write("#{key}=#{value.to_s.strip}\n")
        end
        if data
          stream.write("DataLength=#{data.length}\n")
          stream.write("Data\n")
          stream.write(data)
        else
          stream.write("EndMessage\n")
        end
        stream.flush
      end

      # Read from stream and create a new message object
      def self.read(stream)
        items = {}
        type = nil
        data = nil
        loop do
          line = stream.readline.strip
          case line
          when "End","EndMessage"
            break
          when /=/
            key, value = line.split('=', 2)
            items[key] = value
          when "Data"
            data = stream.read(items['DataLength'].to_i)
            break
          else
            type = line if type == nil
          end
        end
        return Message.new(type, data, items)
      end
    end
  end
end
