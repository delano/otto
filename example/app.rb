

class App
  
  # An instance of Rack::Request
  attr_reader :req
  # An instance of Rack::Response
  attr_reader :res
  
  # Otto creates an instance of this class for every request
  # and passess the Rack::Request and Rack::Response objects.
  def initialize req, res
    @req, @res = req, res
    res.header['Content-Type'] = "text/html; charset=utf-8"
  end
  
  def index
    lines = [
      '<img src="/img/otto.jpg" /><br/>',
      'Send feedback:<br/>',
      '<form method="post"><input name="msg" /><input type="submit" /></form>'
    ]
    res.body = lines.join($/)
  end
  
  def receive_feedback
    res.body = req.params.inspect
  end
  
  def redirect
    res.redirect '/robots.txt'
  end
  
  def robots_text
    res.header['Content-Type'] = "text/plain"
    rules = 'User-agent: *', 'Disallow: /private'
    res.body = rules.join($/)
  end
  
end