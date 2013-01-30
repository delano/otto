

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
      '<img src="/img/otto.jpg" /><br/><br/>',
      'Send feedback:<br/>',
      '<form method="post"><input name="msg" /><input type="submit" /></form>',
      '<a href="/product/100">A product example</a>'
    ]
    res.send_cookie :sess, 1234567, 3600
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

  def display_product
    res.header['Content-Type'] = "application/json; charset=utf-8"
    prodid = req.params[:prodid]
    res.body = '{"product":%s,"msg":"Hint: try another value"}' % [prodid]
  end

  def not_found
    res.status = 404
    res.body = "Item not found!"
  end

  def server_error
    res.status = 500
    res.body = "There was a server error!"
  end

end
