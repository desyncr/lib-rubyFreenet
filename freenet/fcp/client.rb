require 'md5'
require 'socket'
require 'thread'
require 'logger'

module Freenet
  module FCP
    # Implements Freenet Client Protocol client in Ruby. It is multithreaded and mostly thread-safe.
    #
    # == Bugs
    #
    # Probably many. This should get better.
    #
    # == Future Development
    #
    # I hope to add more convinience methods, such as being able to insert data from any IO
    # object instead of strings only. ClientPutDir and ClientPutComplexDir still need to be
    # implemented.
    #
    # Polling-based asynchronous use may be implemented if there's demand.
    #
    # I probably need to tidy up the exception structure.
    #
    # == Examples
    #
    # === Synchronous Use
    #
    # Synchronous use is the easiest way to interface with FCP. The calling thread will block
    # until a response is received from the server. This is limited in use as responses may
    # take a long time.
    #
    # Client names are unique to an application. If your application may have more than one
    # instance per node then each instance must have a unique name. In the event of a name
    # conflict FRED assumes that the original application has died and the new one is a replacement
    # and disconnects the oldest connection.
    #
    # Most methods take a block, this is called with each message received. The arguments are
    # a status code, the request message and the response message. To break out of the response
    # loop raise Freenet::FCP::RequestFinished and any futher responses from the node for the
    # request will be ignored.
    #
    #  require 'freenet/client'
    #  client = Freenet::FCP::Client.new('MyFreenetClient', '127.0.0.1', 9481)
    #  file = client.get("KSK@gpl.txt") do |status, request, response|
    #    case status
    #    when :finished
    #      puts response.data
    #      raise Freenet::FCP::RequestFinished.new
    #    when :failed
    #      puts "Request failed :("
    #      raise Freenet::FCP::RequestFinished.new
    #    end
    #  end
    #
    # See method details for possible status codes. All callbacks may get the following
    # [:error] Freenet reported a ProtocolError
    # 
    # === Asynchronous Use
    #
    # Asynchronous is very similar to synchronous use, except the block is run in a separate thread
    # each time it's called. Your application will need to be thread safe.
    #
    #  client.get("KSK@gpl.txt") do |status, message, response|
    #    case status
    #    when :finished then puts response.data
    #    end
    #  end
    #  # The application will exit here unless you block somehow.
    #
    # ==== Thread safety
    # 
    # In callbacks the messages are locked before the callback runs. Always
    # acquire locks with Message#lock before using, but don't forget to release with Message#unlock.
    #
    # Message#synchronize may be implemented later.
    class Client
      include Logger::Severity

      # Constructor, prepares various settings and connects to the Freenet node
      #
      # [client_name] A unique identifier to your client, it should be the same for all connections.
      #               It allows persistent connections to find old requests
      # [server] The IP of the FCP host, normally 127.0.0.1
      # [port] The associated TCP port, normally 9481
      # [options] Currently unused.
      #
      # raises FCPConnectionError if connection fails
      def initialize(client_name=nil, server="127.0.0.1", port=9481, options={})
        @client_name = client_name || MD5.md5(Time.now.to_s)
        @options, @server, @port = options, server, port
        @messages = {}
        @running = false
        @lock = Mutex.new
        @logger = Logger.new('FCPClientLog','daily')
        @message_queue = Queue.new
        connect
        hello
      end

      # Performs the connection and worker thread creation
      #
      # raises FCPConnectionError if something goes wrong
      def connect
        @lock.synchronize do
          log(INFO, "Connecting to #{@server}:#{@port}")
          @socket = TCPSocket.open(@server, @port)
          @running = true
          @socket_thread = Thread.new {socket_thread}
          log(DEBUG, "Running thread")
        end
      rescue
        raise FCPConnectionError.new('Connection failed')
      end

      # Get the worker thread to disconnect. Doesn't guarantee immediate disconnection
      # as any message currently being read will still be processed
      def disconnect
        log(INFO, 'Disconnecting')
        @lock.synchronize do
          @running = false
        end
        @socket_thread.join if @socket_thread
      end

      # Loads a request in to the queue. This is for persistent requests, read the notes above for more
      # details
      def load_request(message)
        message.load_only = true
        @message_queue << message
      end

      ###
      # Request methods
      ###
      
      # Generates a keypair for SSK use. If used synchronously it returns
      # [InsertURI, RequestURI], otherwise extract InsertURI and RequestURI
      # from response.items
      def generate_keypair(block = true, &callback)
        message = Message.new('GenerateSSK', nil, nil, callback)
        send(message)
        unless block
          message
        else
          message.wait_for_response
          [message.response.items['InsertURI'], message.response.items['RequestURI']]
        end
      end
      
      # == Request a file from Freenet.
      #
      # Applicable status messages:
      # [:pending] The message is in Freenet's queue.
      # [:progress] A SimpleProgress message has been recieved
      # [:redirect] The node has found a redirect for the file. This is returned
      #             to the client so a new request can be started, redirects are
      #             *NOT* followed automatically
      # [:retrying] A non-fatal error has been encountered (eg remote node overloaded)
      #             and a retry is automatically happening. This is controlled by
      #             Message#retries
      # [:failed] The request has failed, more details in the response
      # [:found] The data has been found, but not returned to the client. If ReturnType
      #          is not direct (the default) now is the time to do something
      # [:finished] The data has been returned to the client, response.data has it
      #
      # === Usage Examples
      # ==== Synchronous Use
      #  gpl = client.get('KSK@gpl.txt')
      #
      # ==== Asynchronous use
      #  client.get('KSK@gpl.txt', false, 'Persistence'=>'connection') do |status, message, response|
      #    case status
      #    when :finished then puts response.data
      #    end
      #  end
      def get(uri, block=true, options=nil, &callback)
        uri = uri.uri if uri.respond_to? :uri
        options = {'IgnoreDS'=>false,
                   'DSOnly'=>false,
                   'Verbosity'=>0,
                   'ReturnType'=>'direct',
                   'PriorityClass'=>1,
                   'Persistence'=>'reboot',
                   'Global'=>false}.merge(options || {})
        options['Persistence'] = 'connection' unless async
        options['URI'] = uri
        message = Message.new('ClientGet', nil, options, callback)
        log(INFO, "#{message.identifier} GET queued")
        send(message)
        block_message(message, block)
      end
      
      # === Put data in to freenet
      #
      # This is a very simple put, if you wish to insert a directory then use
      # Client#put_dir or Client#put_complex_dir.
      #
      # Synchronous requests get the inserted URI or a RequestFailed exception.
      # Asynchronous requsts get the following callbacks:
      # [:uri_generated] Freenet has generated the URI (in +response.items['URI']+).
      #                  Insertion hasn't happened at this stage, but the URI is known
      # [:success] The data has been inserted successfully.
      # [:failed] The insertion has failed, response.items contains more information
      #
      # === Usage Examples
      # ==== Putting data from Ruby
      #  put('KSK@my-key', 'This is my text string', false, 'Metadata.ContentType'=> 'text/plain')
      #
      # ==== Putting a file from disk (must be local to server, not client)
      #  put('KSK@my-key', nil, false, 'MetaData.ContentType'=>'text/plain', 'UploadFrom'=>'disk', 'Filename'=>'/full/path/to/file')
      #
      # ==== Creating a redirect URI
      #  put('SSK@my-site-key/my-site/image.jpg', nil, false, 'UploadFrom'=>'redirect','TargetURI'=>'KSK@image.jpg')
      def put(uri, data=nil, block=true, options=nil, &callback)
        uri = uri.uri if uri.respond_to? :uri
        options = {'Metadata.ContentType' => 'application/octet-stream',
                   'Verbosity' => 0,
                   'MaxRetries' => 10,
                   'Persistence' => 'reboot',
                   'UploadFrom' => 'direct'}.merge(options || {})
        options['Persistence'] = 'connection' unless async
        options['URI'] = uri
        message = Message.new('ClientPut', data, options, callback)
        message.content_type = options['Metadata.ContentType']
        log(INFO, "#{message.identifier} PUT queued")
        send(message)
        block_message(message, block)
      end
      
      # Upload a directory to a key, either SSK or USK. This directory must be local to the
      # node we're connecting to.
      def putdir(uri, dir, block=true, options=nil, &callback)
        uri = uri.uri if uri.respond_to? :uri
        options = {'Verbosity' => 0,
                   'MaxRetries' => 10,
                   'PriorityClass' => 3,
                   'DefaultName' => 'index.html',
                   'Filename' => dir.to_s,
                   'AllowUnreadableFiles' => 'true'}.merge(options || {})
        options['Persistence'] = 'connection' unless async
        options['URI'] = uri
        message = Message.new('ClientPutDiskDir', nil, options, callback)
        log(INFO, "#{message.identifier} PUTDIR queued")
        send(message)
        block_message(message, block)
      end
      
      # Get the request status for a persistent request. Not useful in synchronous systems.
      #
      # Any replies will be directed to the async message's callback
      def request_status(identifier, global, async=false)
        log(DEBUG, 'Requesting status')
        message = Message.new('GetRequestStatus', nil, 'Identifier'=>identifier, 'Global'=>global)
        send(message)
        message.wait_for_response
      end

      # Private calls
      private
      
      def block_message(message, block)
        unless block
          message
        else
          loop do
            begin
              message.wait_for_response
              message.lock
              message.response.lock
              callback(message.status, message, message.response)
              message.response.unlock
              message.unlock
            rescue RequestFinished => e
              message.unlock
            end
          end
        end
      end
      
      # Send the ClientHello message to the FCP server.
      def hello
        log(DEBUG, 'Sending ClientHello')
        message = Message.new('ClientHello', nil, 'Name'=>@client_name, 'ExpectedVersion'=>'2.0')
        send(message)
        message.wait_for_response
        log(DEBUG, "Got NodeHello - Freenet #{message.response.items['Version']}")
        if message.response.items['Testnet'] == 'true'
          log(WARN, "Connected to Testnet, you have no anonymity!")
        end
      end

      # Logger utility method. Logger should be thread-safe
      def log(severity, message)
        @logger.add(severity, message)
      end

      # Queue the message for sending by the worker thread.
      # [message] The FCP::Message to send to the server. You may retain object for later use, but
      #           it may block if it's in use.
      def send(message)
        @message_queue << message
        message
      end

      # Worker thread, loops every second or so and checks for new messages to send then messages
      # to receive. It is also responsible for culling the callback threads.
      def socket_thread
        @callback_threads = []
        loop do
          # Join threads. Wait 0.1 seconds for each thread.
          @callback_threads.each do |thread|
            begin
              @callback_threads.delete(thread) if thread.join(0.1)
            rescue RequestFinished=>e
              @messages.delete(e.message)
              @callback_threads.delete(thread)
            rescue Exception=>e
              puts "Callback exception #{e}"
              @callback_threads.delete(thread)
            end
          end
          
          # I'm assuming that setting @running is atomic. There shouldn't be a race
          # condition here as this thread will never set @running.
          if @running == false
            @socket.close
            Thread.exit
          end
          
          begin
            while message = @message_queue.pop(true)
              send_message(message)
            end
          rescue ThreadError => e # If the queue is empty.
          end
          
          # Wait two seconds for communication, shouldn't slow down too much and should save CPU.
          if select([@socket], nil, nil, 2)
            message = read_message
            dispatch_message(message)
          end
          
          @messages.each do |id, message|
            if message.timeout and Time.now > (message.added + message.timeout)
              thread = Thread.new do
                message.callback(:timeout)
                raise RequestFinished.new(message.identifier)
              end
              @callback_threads << thread
            end
          end
        end
      rescue Exception => e
        log(FATAL, "Exception in socket thread: #{e.class}: #{e.message}")
        raise e
      ensure
        @socket.close
      end

      # Dispatch a message received from the server. Sets the reply on the original message and then
      # calls any callback. See above for notes on callbacks.
      def dispatch_message(message)
        if message.identifier
          log(INFO, "#{message.identifier}: recieved #{message.type}")
          original_message = @messages[message.identifier]
          if original_message
            status = message.status
            original_message.reply = message
            if original_message.callback?
              thread = Thread.new do
                original_message.lock
                message.lock
                original_message.callback(status)
                case status
                when :found
                  original_message.content_type = message.items['Metadata.ContentType']
                  if original_message.items['Persistence'] != 'connection' and not original_message.data_found
                    original_message.data_found = true
                    request_status(message.identifier, message.items['Global'] || false, true)
                  end
                when :failed
                  if message.items['Fatal'] == 'false'
                    if message.items['Code'] == 15
                      if original_message.retries < 5
                        original_message.retries += 1
                        log(DEBUG, "Retrying #{original_message.items['URI']}")
                        get(original_message.items['URI'], true, original_message.items)
                      end
                    end
                  end
                end
                message.unlock
                original_message.unlock
              end
              @callback_threads << thread
            end
          else
            log(WARN, 'Got a message for an unknown identifier. Did you forget to reload persistent requests?')
          end
        else
          log(DEBUG, 'Got message with no identifier')
          case message.type
          when 'CloseConnectionDuplicateClientName'
            raise FCPConnectionError.new('DuplicateClientName, disconnecting')
          end
        end
      end

      # Writes an FCP::Message to the server
      #
      # raises FCPConnectionError if socket isn't connected
      def send_message(message)
        raise FCPConnectionError.new('Socket does not exist') unless @socket
        @messages[message.identifier] ||= message
        unless message.load_only
          message.write(@socket)
        end
      end

      # Reads a message from the server and returns an FCP::Message. Does not handle processing
      # the message
      #
      # raises FCPConnectionError if socket isn't connected
      def read_message
        raise FCPConnectionError.new('Socket does not exist') unless @socket
        return Message.read(@socket)
      end
    end
  end
end