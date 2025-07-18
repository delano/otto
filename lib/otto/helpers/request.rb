# lib/otto/helpers/request.rb

class Otto
  module RequestHelpers
    def user_agent
      env['HTTP_USER_AGENT']
    end

    def client_ipaddress
      remote_addr = env['REMOTE_ADDR']

      # If we don't have a security config or trusted proxies, use direct connection
      if !otto_security_config || !trusted_proxy?(remote_addr)
        return validate_ip_address(remote_addr)
      end

      # Check forwarded headers from trusted proxies
      forwarded_ips = [
        env['HTTP_X_FORWARDED_FOR'],
        env['HTTP_X_REAL_IP'],
        env['HTTP_CLIENT_IP']
      ].compact.map { |header| header.split(/,\s*/) }.flatten

      # Return the first valid IP that's not a private/loopback address
      forwarded_ips.each do |ip|
        clean_ip = validate_ip_address(ip.strip)
        return clean_ip if clean_ip && !private_ip?(clean_ip)
      end

      # Fallback to remote address
      validate_ip_address(remote_addr)
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
      return false unless Otto.env?(:dev, :development)

      ip = client_ipaddress
      return false unless ip

      local_or_private_ip?(ip)
    end

    def secure?
      # Check direct HTTPS connection
      return true if env['HTTPS'] == 'on' || env['SERVER_PORT'] == '443'

      remote_addr = env['REMOTE_ADDR']

      # Only trust forwarded proto headers from trusted proxies
      if otto_security_config && trusted_proxy?(remote_addr)
        # X-Scheme is set by nginx
        # X-FORWARDED-PROTO is set by elastic load balancer
        return env['HTTP_X_FORWARDED_PROTO'] == 'https' || env['HTTP_X_SCHEME'] == 'https'
      end

      false
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

    private

    def otto_security_config
      # Try to get security config from various sources
      if respond_to?(:otto) && otto.respond_to?(:security_config)
        otto.security_config
      elsif defined?(Otto) && Otto.respond_to?(:security_config)
        Otto.security_config
      else
        nil
      end
    end

    def trusted_proxy?(ip)
      config = otto_security_config
      return false unless config

      config.trusted_proxy?(ip)
    end

    def validate_ip_address(ip)
      return nil if ip.nil? || ip.empty?

      # Remove any port number
      clean_ip = ip.split(':').first

      # Basic IP format validation
      return nil unless clean_ip.match?(/\A\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\z/)

      # Validate each octet
      octets = clean_ip.split('.')
      return nil unless octets.all? { |octet| (0..255).include?(octet.to_i) }

      clean_ip
    end

    def private_ip?(ip)
      return false unless ip

      # RFC 1918 private ranges and loopback
      private_ranges = [
        /\A10\./,                    # 10.0.0.0/8
        /\A172\.(1[6-9]|2[0-9]|3[01])\./, # 172.16.0.0/12
        /\A192\.168\./,              # 192.168.0.0/16
        /\A169\.254\./,              # 169.254.0.0/16 (link-local)
        /\A224\./,                   # 224.0.0.0/4 (multicast)
        /\A0\./                      # 0.0.0.0/8
      ]

      private_ranges.any? { |range| ip.match?(range) }
    end

    def local_or_private_ip?(ip)
      return false unless ip

      # Check for localhost
      return true if ip == '127.0.0.1' || ip == '::1'

      # Check for private IP ranges
      private_ip?(ip)
    end
  end
end
