module Freenet
  # Raised if a URI can't be parsed or handled for some reason
  class URIError < StandardError
  end
  
  # Raised if a feature isn't implemented by a URI, eg versioning for CHKs
  class URIMethodNotImplementedError < StandardError
  end
end