# lib/otto/helpers/response.rb

class Otto
  module ResponseHelpers
    attr_accessor :request

    def send_secure_cookie(name, value, ttl)
      send_cookie name, value, ttl, true
    end

    def send_cookie(name, value, ttl, secure = true)
      secure = false if request.local?
      opts = {
        value: value,
        path: '/',
        expires: (Time.now.utc + ttl + 10),
        secure: secure
      }
      # opts[:domain] = request.env['SERVER_NAME']
      set_cookie name, opts
    end

    def delete_cookie(name)
      send_cookie name, nil, -1.day
    end
  end
end
