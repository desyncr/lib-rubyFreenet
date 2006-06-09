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
    # and disconnects the oldest connection,
    #
    #  require 'freenet/client'
    #  client = Freenet::FCP::Client.new('MyFreenetClient', '127.0.0.1', 9481)
    #  file = client.get("KSK@gpl.txt")
    # 
    # === Asynchronous Use
    #
    # There are two methods to asynchronous requests, both with their own merits
    #
    # ==== Polling
    # 
    # Polling is not implemented yet, but Messages will have a ResponseQueue where responses
    # can be read in order or recipt.
    #
    # ==== Callbacks
    #
    # FCP::Message can take a block to run as soon as a reply is received. These blocks run
    # in a separate thread, so they must be thread safe if they use variables outside their
    # scope. The block arguments are |status, message, response|, message is the original 
    # message for reference purposes.
    #
    #  client.get("KSK@gpl.txt") do |status, message, response|
    #    case status
    #    when :finished then puts response.data
    #    end
    #  end
    #
    # See method details for possible status codes. All callbacks may get the following
    # [:error] Freenet reported a ProtocolError
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
        @logger_mutex = Mutex.new
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
      def generate_keypair(async = false, &callback)
        message = Message.new('GenerateSSK', nil, nil, callback)
        send(message, async)
        if async
          message
        else
          [message.response.items['InsertURI'], message.response.items['RequestURI']]
        end
      end
      
      # == Request a file from Freenet.
      #
      # Synchronous requests will either get the response message or a RequestFailed exception
      # 
      # Asyncronous requests get a lot more status information. The messages are:
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
      def get(uri, async=false, options=nil, &callback)
        uri = uri.uri if uri.respond_to? :uri
        async = true if callback
        options = {'IgnoreDS'=>false,
                   'DSOnly'=>false,
                   'Verbosity'=>1,
                   'ReturnType'=>'direct',
                   'PriorityClass'=>1,
                   'Persistence'=>'reboot',
                   'Global'=>false}.merge(options || {})
        options['Persistence'] = 'connection' unless async
        options['URI'] = uri
        message = Message.new('ClientGet', nil, options, callback)
        send(message, async)
        if async
          message
        else
          loop do
            message.lock
            case message.response.type
            when 'AllData'
              message.unlock
              return message.response
            when 'GetFailed'
              message.unlock
              raise RequestFailed.new(message.response)
            else
              message.unlock
            end
          end
        end
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
      def put(uri, data=nil, async=false, options=nil, &callback)
        uri = uri.uri if uri.respond_to? :uri
        async = true if callback
        options = {'Metadata.ContentType' => 'application/octet-stream',
                   'Verbosity' => 1,
                   'MaxRetries' => 10,
                   'Persistence' => 'reboot',
                   'UploadFrom' => 'direct'}.merge(options || {})
        options['Persistence'] = 'connection' unless async
        options['URI'] = uri
        message = Message.new('ClientPut', data, options, callback)
        message.content-type = options['Metadata.ContentType']
        send(message, async)
        if async
          message
        else
          loop do
            message.lock
            case message.response.type
            when 'PutSuccessful'
              message.unlock
              return message.response.items['URI']
            when 'PutFailed'
              message.unlock
              raise RequestFailed.new(message.response)
            else
              message.unlock
            end
          end
        end
      end
      
      # Upload a directory to a key, either SSK or USK. This directory must be local to the
      # node we're connecting to.
      def putdir(uri, dir, async=false, options=nil, &callback)
        uri = uri.uri if uri.respond_to? :uri
        async = true if callback
        options = {'Verbosity' => 1,
                   'MaxRetries' => 10,
                   'PriorityClass' => 3,
                   'DefaultName' => 'index.html',
                   'Filename' => dir.to_s,
                   'AllowUnreadableFiles' => 'true'}.merge(options || {})
        options['Persistence'] = 'connection' unless async
        options['URI'] = uri
        message = Message.new('ClientPutDiskDir', nil, options, callback)
        send(message, async)
        if async
          message
        else
          loop do
            message.lock
            case message.response.type
            when 'PutSuccessful'
              message.unlock
              return message.response.items['URI']
            when 'PutFailed'
              message.unlock
              raise RequestFailed.new(message.response)
            else
              message.unlock
            end
          end
        end
      end
      
      # Get the request status for a persistent request. Not useful in synchronous systems.
      #
      # Any replies will be directed to the async message's callback
      def request_status(identifier, global, async=false)
        log(DEBUG, 'Requesting status')
        message = Message.new('GetRequestStatus', nil, 'Identifier'=>identifier, 'Global'=>global)
        send(message, async)
      end

      private
      # Send the ClientHello message to the FCP server.
      def hello
        log(DEBUG, 'Sending ClientHello')
        message = Message.new('ClientHello', nil, 'Name'=>@client_name, 'ExpectedVersion'=>'2.0')
        send(message)
        log(DEBUG, "Got NodeHello - Freenet #{message.response.items['Version']}")
        if message.response.items['Testnet'] == 'true'
          log(WARN, "Connected to Testnet, you have no anonymity!")
        end
      end

      # Logger utility method
      def log(severity, message)
        @logger_mutex.synchronize {@logger.add(severity, message)}
      end

      # Queue the message for sending by the worker thread.
      # [message] The FCP::Message to send to the server. You may retain object for later use, but
      #           it may block if it's in use.
      # param asynchronous Whether the reader should block until a response is received
      def send(message, asynchronous = false)
        log(DEBUG, "Queuing #{message.type} - #{message.identifier}")
        @message_queue << message
        unless asynchronous
          return message.wait_for_response
        end
      end

      # Worker thread, loops every second or so and checks for new messages to send then messages
      # to receive. It is also responsible for culling the callback threads.
      def socket_thread
        @callback_threads = []
        loop do
          @callback_threads.each do |thread|
            begin
              thread.join(0.1)
            rescue RequestFinished=>e
              @messages.delete(e.message)
            rescue Exception=>e
              puts "Callback exception #{e}"
            end
          end
          @lock.synchronize do
            if @running == false
              @socket.close
              Thread.exit
            end
          end
          begin
            while message = @message_queue.pop(true)
              send_message(message)
            end
          rescue ThreadError => e
          end

          if select([@socket], nil, nil, 1)
            message = read_message
            dispatch_message(message)
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
        log(DEBUG, "Dispatching #{message.type} - #{message.identifier}")
        if message.identifier
          original_message = @messages[message.identifier]
          if original_message
            original_message.reply = message
            thread = Thread.new do
              original_message.lock
              message.lock
              case message.type
              when 'SSKKeypair'
                original_message.callback(:keypair)
              when 'AllData'
                original_message.callback(:finished)
              when 'PersistentGet'
                original_message.callback(:pending)
              when 'SimpleProgress'
                original_message.callback(:progress)
              when 'ProtocolError'
                original_message.callback(:failed)
              when 'URIGenerated'
                original_message.callback(:uri_generated)
              when 'PutSuccessful'
                original_message.callback(:success)
              when 'PutFailed'
                original_message.callback(:failed)
              when 'ProtocolError'
                original_message.callback(:error)
              when 'DataFound'
                original_message.callback(:found)
                original_message.content_type = message.items['Metadata.ContentType']
                if original_message.items['Persistence'] != 'connection' and not original_message.data_found
                  original_message.data_found = true
                  request_status(message.identifier, message.items['Global'] || false, true)
                end
              when 'GetFailed'
                if message.items['RedirectURI']
                  original_message.callback(:redirect)
                elsif message.items['Fatal'] == 'false'
                  case message.items['Code']
                  when '15' # Node overloaded. Wait then re-request. We can re-use the ID as GetFailed removes the ID from FRED
                    if original_message.retries < 5
                      original_message.retries += 1
                      original_message.callback(:retrying)
                      log(DEBUG, "Retrying #{original_message.items['URI']}")
                      get(original_message.items['URI'], true, original_message.items)
                    else
                      original_message.callback(:failed)
                    end
                  else
                    original_message.callback(:failed)
                  end
                else
                  original_message.callback(:failed)
                end
              end
              message.unlock
              original_message.unlock
            end
            @callback_threads << thread
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
        log(DEBUG, "Sending #{message.type} #{message.identifier}")
        @messages[message.identifier] ||= message
        unless message.load_only
          log(DEBUG, "W: #{message.type}")
          @socket.write(message.type+"\n")
          message.items.each do |key, value|
            log(DEBUG, "W: #{key}=#{value}")
            @socket.write("#{key}=#{value}\n")
          end

          if message.data
            @socket.write("DataLength=#{message.data.length}\n")
            log(DEBUG, "W: DataLength=#{message.data.length}")
            @socket.write("Data\n")
            log(DEBUG, "W: Data")
            @socket.write(message.data)
            log(DEBUG, "W: #{message.data}")
          else
            @socket.write("EndMessage\n")
            log(DEBUG, "W: EndMessage")
          end
          @socket.write("\n")
        end
      end

      # Reads a message from the server and returns an FCP::Message. Does not handle processing
      # the message
      #
      # raises FCPConnectionError if socket isn't connected
      def read_message
        raise FCPConnectionError.new('Socket does not exist') unless @socket
        items = {}
        type = nil
        data = nil
        loop do
          line = @socket.readline.strip
          log(DEBUG, "R: #{line}")
          case line
          when "End","EndMessage"
            break
          when /=/
            key, value = line.split('=', 2)
            items[key] = value
          when "Data"
            log(DEBUG, "Reading #{items['DataLength']} bytes")
            data = @socket.read(items['DataLength'].to_i)
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