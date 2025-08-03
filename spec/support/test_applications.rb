# frozen_string_literal: true

# Mock application classes for testing routes
class TestApp
  def self.index(req, res)
    res.write('Hello World')
  end

  def self.show(req, res)
    res.write("Showing #{req.params['id']}")
  end

  def self.user_post(req, res)
    res.write("User #{req.params['user_id']} Post #{req.params['post_id']}")
  end

  def self.search(req, res)
    res.write("Search results")
  end

  def self.create(req, res)
    res.write('Created')
  end

  def self.update(req, res)
    res.write("Updated #{req.params['id']}")
  end

  def self.destroy(req, res)
    res.write("Deleted #{req.params['id']}")
  end

  def self.error_test(req, res)
    raise StandardError, 'Test error'
  end

  def self.custom_headers(req, res)
    res.headers['X-Custom-Header'] = 'test-value'
    res.write('Custom headers')
  end

  def self.json_response(req, res)
    res.headers['Content-Type'] = 'application/json'
    res.write('{"message": "Hello JSON"}')
  end

  def self.html_response(req, res)
    res.headers['Content-Type'] = 'text/html'
    res.write('<html><head></head><body><h1>Hello HTML</h1></body></html>')
  end
end

class TestInstanceApp
  def initialize(req, res)
    @req = req
    @res = res
  end

  def show
    @res.write("Instance showing #{@req.params['id']}")
  end
end