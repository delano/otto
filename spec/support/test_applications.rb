# frozen_string_literal: true
# spec/support/test_applications.rb

# Mock application classes for testing routes
class TestApp
  def self.index(_req, res)
    res.write('Hello World')
  end

  def self.show(req, res)
    res.write("Showing #{req.params['id']}")
  end

  def self.user_post(req, res)
    res.write("User #{req.params['user_id']} Post #{req.params['post_id']}")
  end

  def self.search(_req, res)
    res.write('Search results')
  end

  def self.create(_req, res)
    res.write('Created')
  end

  def self.update(req, res)
    res.write("Updated #{req.params['id']}")
  end

  def self.destroy(req, res)
    res.write("Deleted #{req.params['id']}")
  end

  def self.error_test(_req, _res)
    raise StandardError, 'Test error'
  end

  def self.custom_headers(_req, res)
    res.headers['X-Custom-Header'] = 'test-value'
    res.write('Custom headers')
  end

  def self.json_response(_req, res)
    res.headers['Content-Type'] = 'application/json'
    res.write('{"message": "Hello JSON"}')
  end

  def self.html_response(_req, res)
    res.headers['Content-Type'] = 'text/html'
    res.write('<html><head></head><body><h1>Hello HTML</h1></body></html>')
  end

  def self.test(_req, res)
    res.write('test response')
  end

  def self.signin(_req, res)
    res.write('signin response')
  end

  def self.api_users(_req, res)
    res.write('api users response')
  end

  def self.json_data(_req, _res)
    # Return data for JSON handler
    { message: 'Hello JSON', timestamp: Time.now.to_i }
  end

  def self.redirect_test(_req, _res)
    # Return redirect path
    '/redirected'
  end

  def self.view_test(_req, _res)
    # Return HTML content
    '<h1>View Test</h1>'
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

# Namespaced test classes for enhanced routing tests
module V2
  module Logic
    module Admin
      class Panel
        def self.Panel(_req, res)
          res.write('admin panel response')
        end
      end
    end
  end
end
