class Otto
  module RequestHelpers
    def user_agent
      env['HTTP_USER_AGENT']
    end

    def client_ipaddress
      env['HTTP_X_FORWARDED_FOR'].to_s.split(/,\s*/).first ||
        env['HTTP_X_REAL_IP'] || env['REMOTE_ADDR']
    end

    def request_method
      env['REQUEST_METHOD']
    end

    def current_server
      [current_server_name, env['SERVER_PORT']].join(':')
    end

    def current_server_name
      env['SERVER_NAME']
    end

    def http_host
      env['HTTP_HOST']
    end

    def request_path
      env['REQUEST_PATH']
    end

    def request_uri
      env['REQUEST_URI']
    end

    def root_path
      env['SCRIPT_NAME']
    end

    def absolute_suri(host = current_server_name)
      prefix = local? ? 'http://' : 'https://'
      [prefix, host, request_path].join
    end

    def local?
      Otto.env?(:dev, :development) &&
        (client_ipaddress == '127.0.0.1' ||
        !client_ipaddress.match(/^10\.0\./).nil? ||
        !client_ipaddress.match(/^192\.168\./).nil?)
    end

    def secure?
      # X-Scheme is set by nginx
      # X-FORWARDED-PROTO is set by elastic load balancer
      env['HTTP_X_FORWARDED_PROTO'] == 'https' || env['HTTP_X_SCHEME'] == 'https'
    end

    # See: http://stackoverflow.com/questions/10013812/how-to-prevent-jquery-ajax-from-following-a-redirect-after-a-post
    def ajax?
      env['HTTP_X_REQUESTED_WITH'].to_s.downcase == 'xmlhttprequest'
    end

    def cookie(name)
      cookies[name.to_s]
    end

    def cookie?(name)
      !cookie(name).to_s.empty?
    end

    def current_absolute_uri
      prefix = secure? && !local? ? 'https://' : 'http://'
      [prefix, http_host, request_path].join
    end
  end
end
