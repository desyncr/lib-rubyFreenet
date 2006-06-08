module Freenet
  module FCP
    # Raised if an FCP connection can't be made or if the
    # connection dies.
    class FCPConnectionError < Exception
    end
    
    # If raised by a callback the entry is removed from the message list
    # and the identifier can be reused properly
    class RequestFinished < Exception
    end
    
    # Raised if a synchronous request fails
    class RequestFailed < Exception
      attr_reader :code, :description, :extra, :fatal
      def initialize(original_message)
        @code = original_message.items['Code']
        @description = original_message.items['CodeDescription']
        @extra = original_message.items['ExtraDescription']
        @fatal = original_message.items['Fatal']
      end
    end
  end
end