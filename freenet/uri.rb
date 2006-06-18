require 'cgi'
require 'uri'

module Freenet
  # Represents a Freenet URI. Provides manipulation with awareness of the Freenet structure, such
  # as USK versioning.
  #
  # This could be completely wrong. Any criticism welcome
  class URI
    include Comparable
    attr_accessor :type, :key, :name, :path, :uri, :version
    
    # This can take a URI in following formats:
    #  /freenet:SSK@...
    #  SSK@...
    #
    # Currently supports SSK, USK, KSK and CHK
    def initialize(uri = nil)
      return if uri.nil?
      uri = uri.respond_to?(:uri) ? uri.uri : uri.dup
      uri = CGI::unescape(uri)
      case uri
      when /^\/?freenet:/
        uri.sub!(/^\/?freenet:/,'')
      when /^\//
        uri.sub!(/^\//, '')
      end
      raise URIError.new("Invalid Freenet URI: #{uri}") unless uri =~ /^(?:[UKS]S|CH)K@/
      
      @uri = uri
      @type = @uri.match(/^(?:[UKS]S|CH)K/)[0]
      @key = @uri.match(/^(?:[UKS]S|CH)K@([^\/]+)/)[1]
      case @type
      when 'CHK'
        @path = @uri.match(/\/([^#\?]+)/)[1] if @uri =~ /\/[^#\?]+/
      when 'SSK'
        path = @uri.match(/(\/[^#\?]+)/)[1] if @uri =~ /\/[^#\?]+/
        if path
          parts = @uri.match(%r{/([^/]+?)(?:-([0-9]+))?/(.*)})
          @name = parts[1]
          @version = parts[2].to_i if parts[2]
          @path = parts[3]
        end
      when 'USK'
        path = @uri.match(/(\/[^#\?]+)/)[1] if @uri =~ /\/[^#\?]+/
        if path
          parts = @uri.match(%r{/([^/]+?)[/-](-?[0-9]+)/?(.*)})
          @name = parts[1]
          @version = parts[2].to_i
          @path = parts[3]
        end
      end
      @anchor = @uri.match(/#(.+)/)[1] if @uri =~ /#.+/
      @query_string = @uri.match(/\?([^#]+)/)[1] if @uri =~ /\?/
    end
    
    def name=(name)
      raise URIMethodNotImplementedError.new if ['KSK', 'CHK'].include? @type
      @name = name
    end
    
    def version=(version)
      raise URIMethodNotImplementedError.new if ['KSK', 'CHK'].include? @type
      @version = version
    end
    
    def site
      self.key
    end
    
    def site=(site)
      self.key=(site)
    end
    
    def path=(path)
      raise URIMethodNotImplementedError.new if ['KSK'].include? @type
      @path = path
    end
    
    def next_version
      raise URIMethodNotImplementedError.new if ['KSK', 'CHK'].include? @type
      u = self.dup
      u.version = @version+1
      u
    end

    # Return a URI that can be fed to Freenet
    def uri
      case @type
      when 'KSK'
        "#{@type}@#{@key}"
      when 'CHK'
        "#{@type}@#{@key}/#{@path}"
      when 'USK'
        "#{@type}@#{@key}/#{@name}/#{@version.to_s}/#{@path}#{"?#{@query_string}" if @query_string}#{"##{@anchor}" if @anchor}"
      when 'SSK'
        "#{@type}@#{@key}/#{@name}#{'-'+@version.to_s if @version}/#{@path}#{"?#{@query_string}" if @query_string}#{"##{@anchor}" if @anchor}"
      end
    end
    
    # Merge in a URI or a URI fragment and provide the finished URI. Attempts
    # to do what a browser would
    #  uri.merge("image.jpg")
    def merge(uri)
      if uri =~ /^\// or uri =~ /^freenet:/ or uri =~ /^(?:[UKS]S|CH)K/
        return uri
      end
      uri = uri.strip
      begin
        uri = URI.new(uri) unless uri.respond_to? :uri
        if uri.key == @key
          return merge_uri(uri)
        else
          return uri.uri
        end
      rescue URIError => e # We have a fragment
        if uri =~ /([^#\?]+)/
          uri = uri.match(/([^#\?]+)/)[1] 
        else
          raise URIError.new
        end
        raise URIError.new if uri =~ /[^\/]+:/
        
        case @type
        when 'KSK','CHK' #No point merging paths for this type...
        when 'USK'
          "#{@type}@#{@key}/#{@name}#{'/'+@version.to_s if @version}/#{merge_paths(@path, uri)}"
        when 'SSK'
          "#{@type}@#{@key}/#{@name}#{'-'+@version.to_s if @version}/#{merge_paths(@path, uri)}"
        end
      end
    end
    
    # Returns true if we're at the 'base' page of a URI using the following:
    # - KSKs and CHKs only have one file, so always the base
    # - SSKs have a 'base', eg SSK@.../mysite-2/
    # - USKs start with /sitename and end with /revision or  -revision, though the latter
    #   is technically wrong.
    #
    # This may be completely wrong. Please tell me if it is.
    def root?
      case @key
      when /^CHK/ then true
      when /^KSK/ then true
      when /^SSK/ then @path == %r{/[^/]/}
      when /^USK/ then @path =~ %r{/[^/-]+[/-][0-9]+}i
      else
        false 
      end
    end
    
    def <=>(other)
      if other.key == @key
        other.path <=> @path
      else
        other.key <=> @key
      end
    end
    
    private
    
    def merge_uri(uri)
      return uri.uri if uri.type != @type or uri.key != @key
      return uri.uri if ['KSK','CHK'].include? uri.type or ['KSK','CHK'].include? @type
      version = uri.version > @version ? uri.version : version
      name = uri.name
      path = merge_paths(@path, uri.path)
      uri = URI.new
      uri.type = @type
      uri.key = @key
      uri.version = version
      uri.name = name
      uri.path = path
      uri.uri
    end
    
    def merge_paths(old_path, new_path)
      old_parts = old_path.split('/')
      old_parts.pop unless old_path =~ %r{/$}
      new_parts = new_path.split('/')
      while new_parts[0] == '..'
        old_parts.pop
        new_parts.shift
      end
      new_parts.shift while new_parts[0] == '.'
      return (old_parts+new_parts).join('/')
    end
  end
end