$:.push('../')
require 'freenet'

module Freenet
  class Site
    attr_accessor :version, :client, :keys, :name
    def self.load(file)
      Marshal.load(IO.read(file))
    end
    
    def initialize(type, path, name)
      raise SiteError.new('Invalid type') unless ['USK','SSK','CHK','KSK'].include? type
      @path, @type, @name = path, type, name
      @version = ''
    end
    
    def connect
      @client = Freenet::FCP::Client.new()
    end
    
    def generate_key
      @keys = @client.generate_keypair
    end
    
    def process_site
      
    end
    
    # Insert a whole site from disk
    def insert_site(path = nil)
      path ||= @path
      case @type
      when 'CHK', 'KSK' then raise SiteError.new('Invalid key type for site insert')
      end
      generate_key unless @keys
      @uri ||= Freenet::URI.new(@keys[0])
      @uri.type = @type
      @uri.path = "/#{@name}"
      @uri.version ||= 0
      @uri.version += 1
      puts "Insert key: #{@uri.uri}\nRequest key: #{@uri.uri}"
      @client.putdir(@uri, path)
    end
    
    # Insert a single file. You probably want a CHK for this, use it to insert
    # large files that won't change, eg media files.
    #
    # path must be the full filesystem path to the file.
    #
    # If the type is CHK then site isn't used as CHKs are generated by the node. You may 
    # append any text after the / in a CHK URI
    #
    # If the type is KSK then site is the key
    # If the type is SSK or USK then it must be sitename/filename
    def insert_file(path, type = nil, site=nil)
      uri = ''
      type ||= @type
      case type
      when 'CHK' then uri = 'CHK@'
      else
        raise SiteError.new('Invalid key') unless site
        uri = "#{@type}@#{site}"
      end
      @client.put(uri, nil, true, 'UploadFrom'=>'disk','Filename'=>path) do |status, message, response|
        case status
        when :uri_generated
          puts "URI created: #{response.items['URI']}"
        when :success
          puts "File inserted successfully"
        when :failed
          puts "File insertion failed!"
        end
      end
    end
    
    def save(file)
      client = @client
      @client = nil
      File.open(file, 'w') {|f| f.write(Marshal.dump(self))}
      @client = client
    end
  end
  
  class SiteError < StandardError
  end
end