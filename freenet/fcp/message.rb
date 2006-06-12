require 'md5'
require 'thread'

module Freenet
  module FCP
    # An FCP::Message represents a communication between the server and client. It handles basic information
    # and thread safety. When a response is received the original FCP::Message gets its response attribute
    # set to the response FCP::Message
    #
    # Attributes of interest
    # [load_only] Only load in to the message queue, don't actually send. Used when restoring persistent
    #             requests if a client dies
    # [content_type] The content type of the data. Set automatically on response, set manually when inserting.
    # [retries] 
    class Message
      attr_reader :type, :data, :items, :identifier
      attr_accessor :callback, :load_only, :response, :data_found, :content_type, :retries, :timeout, :added

      # [type] The FCP message type
      # [data] Any data to send with the message
      # [items] A hash of message parameters
      # [callback] Callback for asynchronous messages
      def initialize(type, data = nil, items = [], callback = nil)
        @retries = 0
        @type, @data, @items = type.to_s, data, items
        @items = {} unless @items.kind_of? Hash
        @items['Identifier'] ||= "FCPMessage_#{MD5.md5(Time.now.to_s)}_#{rand(100000)}"
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
        @mutex = Mutex.new
        @load_only = false
        @this_thread = nil
        @added = Time.now
      end
      
      # Lock the object. Call before using in async situations
      def lock(delay = 5)
        until @mutex.try_lock
          sleep(delay)
        end
      end
        
      # Unlock. Call after using asychronously
      def unlock
        @mutex.unlock
      end
      
      def locked?
        @mutex.locked?
      end
        
      def try_lock
        @mutex.try_lock
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
      def reply=(response)
        lock
        @response = response
        unlock
        @this_thread.run if @this_thread
      end

      # Used to block until the reply is received for synchronous messages. May be
      # called from any thread.
      def wait_for_response
        @this_thread = Thread.current
        Thread.stop
      end
    end
  end
end