require 'cgi'

module Freenet
  # Represents a Freenet URI. Provides manipulation with awareness of the Freenet structure, such
  # as USK versioning.
  #
  # This could be completely wrong. Any criticism welcome
  class URI
    include Comparable
    attr_accessor :type, :site, :name, :path, :uri, :version
    
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
      @site = @uri.match(/^(?:[UKS]S|CH)K@([^\/]+)/)[1]
      case @type
      when 'KSK', 'CHK'
        @path = @uri.match(/(\/[^#\?]+)/)[1] if @uri =~ /\/[^#\?]+/
      when 'SSK'
        path = @uri.match(/(\/[^#\?]+)/)[1] if @uri =~ /\/[^#\?]+/
        if path
          parts = @uri.match(%r{(/[^/]+?)(?:-([0-9]+))?(/.*)})
          @name = parts[1]
          @version = parts[2]
          @path = parts[3]
        end
      when 'USK'
        path = @uri.match(/(\/[^#\?]+)/)[1] if @uri =~ /\/[^#\?]+/
        if path
          parts = @uri.match(%r{(/[^/]+?)(?:[/-](-?[0-9]+))(/?.*)})
          @name = parts[1]
          @version = parts[2]
          @path = parts[3]
        end
      end
      @anchor = @uri.match(/#(.+)/)[1] if @uri =~ /#.+/
      @query_string = @uri.match(/\?([^#]+)/)[1] if @uri =~ /\?/
    end

    # Return a URI that can be fed to Freenet
    def uri
      case @type
      when 'KSK','CHK'
        "#{@type}@#{@site}#{@path}"
      when 'USK'
        "#{@type}@#{@site}#{@name}#{'/'+@version.to_s if @version}#{"?#{@query_string}" if @query_string}#{@path}#{"##{@anchor}" if @anchor}"
      when 'SSK'
        "#{@type}@#{@site}#{@name}#{'-'+@version.to_s if @version}#{"?#{@query_string}" if @query_string}#{@path}#{"##{@anchor}" if @anchor}"
      end
    end
    
    # Merge in a URI or a URI fragment and provide the finished URI. Attempts
    # to do what a browser would
    #  uri.merge("image.jpg")
    def merge(uri)
      if uri =~ /^\//
        return uri
      end
      uri = uri.strip
      begin
        uri = URI.new(uri) unless uri.respond_to? :uri
        if uri.site == @site
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
          "#{@type}@#{@site}#{@name}#{'/'+@version.to_s if @version}#{merge_paths(@path, uri)}"
        when 'SSK'
          "#{@type}@#{@site}#{@name}#{'-'+@version.to_s if @version}#{merge_paths(@path, uri)}"
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
      case @site
      when /^CHK/ then true
      when /^KSK/ then true
      when /^SSK/ then @path == %r{/[^/]/}
      when /^USK/ then @path =~ %r{/[^/-]+[/-][0-9]+}i
      else
        false 
      end
    end
    
    def <=>(other)
      if other.site == @site
        other.path <=> @path
      else
        other.site <=> @site
      end
    end
    
    private
    
    def merge_uri(uri)
      return uri.uri if uri.type != @type or uri.site != @site
      version = uri.version > @version ? uri.version : version
      name = uri.name
      path = merge_paths(@path, uri.path)
      uri = URI.new
      uri.type = @type
      uri.site = @site
      uri.version = version
      uri.name = name
      uri.path = path
      uri.uri
    end
    
    def merge_paths(old_path, new_path)
      case new_path
      when /^\.\.\//
        unless old_path =~ /\/$/
          old_path = old_path.gsub(/\/[^\/]+$/, '')
        end
        old_path = old_path.gsub(/\/[^\/]+$/,'/')
        new_path = new_path.gsub(/^\.\.\//, '')
        return merge_paths(old_path, new_path)
      when /^\.\//
        unless old_path =~ /\/$/
          old_path = old_path.gsub(/\/[^\/]+$/, '/')
        end
        new_path = new_path.gsub(/\.\//,'')
        return "#{old_path}#{new_path}"
      when /^\//
        return new_path
      else
        unless old_path =~ /\/$/
          old_path = old_path.gsub(/\/[^\/]+$/, '/')
        end
        return "#{old_path}#{new_path}"
      end
    end
  end
end