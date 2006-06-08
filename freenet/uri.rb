module Freenet
  # Represents a Freenet URI. Provides manipulation with awareness of the Freenet structure, such
  # as USK versioning.
  #
  # This could be completely wrong. Any criticism welcome
  class URI
    include Comparable
    attr_reader :site, :path, :uri
    
    # This can take a URI in following formats:
    #  /freenet:SSK@...
    #  SSK@...
    #
    # Currently supports SSK, USK, KSK and CHK
    def initialize(uri)
      uri = uri.respond_to?(:uri) ? uri.uri : uri.dup
      case uri
      when /^\/?freenet:/
        uri.sub!(/^\/?freenet:/,'')
      when /^\//
        uri.sub!(/^\//, '')
      end
      raise URIError.new("Invalid Freenet URI: #{uri}") unless uri =~ /^(?:[UKS]S|CH)K@/
      
      @uri = uri
      @site = @uri.match(/^(?:[UKS]S|CH)K@[^\/]+/)[0]
      @path = @uri.match(/(\/[^#\?]+)/)[1] if @uri =~ /\/[^#\?]+/
      @anchor = @uri.match(/#(.+)/)[1] if @uri =~ /#.+/
      @query_string = @uri.match(/\?([^#]+)/)[1] if @uri =~ /\?/
    end

    # Return a URI that can be fed to Freenet
    def uri
      "#{@site}#{@path}#{"?#{@query_string}" if @query_string}#{"##{@anchor}" if @anchor}"
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
          return "#{@site}#{merge_paths(@path, uri.path)}"
        else
          return uri.uri
        end
      rescue URIError => e # We have a fragment
        "#{@site}#{merge_paths(@path, uri)}"
      end
    end
    
    # Returns true if we're at the 'base' page of a URI using the following:
    # - KSKs and CHKs only have one file, so always the base
    # - SSKs have a 'base', eg SSK@.../mysite/
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
        return "#{old_path}#{new_path}"
      end
    end
  end
end