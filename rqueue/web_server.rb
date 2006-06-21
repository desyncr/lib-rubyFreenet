require 'webrick'
require 'erb'
require 'cgi'
include WEBrick

class QueueWeb < HTTPServlet::AbstractServlet
  def self.start_server(port)
    s = HTTPServer.new(:Port=>port)
    s.mount('/', QueueWeb)
    trap("INT") do
      s.shutdown
      DRb.stop_service
    end
    s.start
  end
  
  def initialize(server)
    super(server)
    DRb.start_service()
    @drb = DRbObject.new(nil, 'druby://localhost:9876')
    File.open('templates/index.rhtml') do |f|
      @template = ERB.new(f.read, nil, '-')
    end
  end
  
  def do_GET(req, res)
    case req.path
    when '/download'
      params = CGI::parse(req.query_string)
      status = @drb.status
      item = status[params['uri'][0]]
      res['Content-Type'] = item[:content_type] if item[:content_type] != ''
      res.body = item[:data]
    when '/remove'
      params = CGI::parse(req.query_string)
      @drb.remove(params['uri'][0])
      res.status = 302
      res['Location'] = '/'
    else
      res['Content-Type'] = 'text/html'
      @status = @drb.status
      res.body = @template.result(binding)
    end
  end
  
  def do_POST(req, res)
    case req.path
    when '/add_uris'
      params = CGI::parse(req.body)
      params['uris'].each do |uris|
        @drb.add_uris(*(uris.split(/\r|\n/)))
      end
      res.status = 302
      res['Location'] = '/'
    else
    end
  end
end