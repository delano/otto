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
        env['HTTP_CLIENT_IP'],
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
      return nil unless octets.all? { |octet| (0..255).cover?(octet.to_i) }

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
        /\A0\./,                      # 0.0.0.0/8
      ]

      private_ranges.any? { |range| ip.match?(range) }
    end

    def local_or_private_ip?(ip)
      return false unless ip

      # Check for localhost
      return true if ['127.0.0.1', '::1'].include?(ip)

      # Check for private IP ranges
      private_ip?(ip)
    end

    # Collect and format HTTP header details from the request environment
    #
    # This method extracts and formats specific HTTP headers, including
    # Cloudflare and proxy-related headers, for logging and debugging purposes.
    #
    # @param header_prefix [String, nil] Custom header prefix to include (e.g. 'X_SECRET_')
    # @param additional_keys [Array<String>] Additional header keys to collect
    # @return [String] Formatted header details as "key: value" pairs
    #
    # @example Basic usage
    #   collect_proxy_headers
    #   # => "X-Forwarded-For: 203.0.113.195 Remote-Addr: 192.0.2.1"
    #
    # @example With custom prefix
    #   collect_proxy_headers(header_prefix: 'X_CUSTOM_')
    #   # => "X-Forwarded-For: 203.0.113.195 X-Custom-Token: abc123"
    def collect_proxy_headers(header_prefix: nil, additional_keys: [])
      keys = %w[
        HTTP_FLY_REQUEST_ID
        HTTP_VIA
        HTTP_X_FORWARDED_PROTO
        HTTP_X_FORWARDED_FOR
        HTTP_X_FORWARDED_HOST
        HTTP_X_FORWARDED_PORT
        HTTP_X_SCHEME
        HTTP_X_REAL_IP
        HTTP_CF_IPCOUNTRY
        HTTP_CF_RAY
        REMOTE_ADDR
      ]

      # Add any header that begins with the specified prefix
      if header_prefix
        prefix_keys = env.keys.select { |key| key.upcase.start_with?("HTTP_#{header_prefix.upcase}") }
        keys.concat(prefix_keys)
      end

      # Add any additional keys requested
      keys.concat(additional_keys) if additional_keys.any?

      keys.sort.filter_map do |key|
        value = env[key]
        next unless value

        # Normalize the header name to look like browser dev console
        # e.g. Content-Type instead of HTTP_CONTENT_TYPE
        pretty_name = key.sub(/^HTTP_/, '').split('_').map(&:capitalize).join('-')
        "#{pretty_name}: #{value}"
      end.join(' ')
    end

    # Format request details as a single string for logging
    #
    # This method combines IP address, HTTP method, path, query parameters,
    # and proxy header details into a single formatted string suitable for logging.
    #
    # @param header_prefix [String, nil] Custom header prefix for proxy headers
    # @return [String] Formatted request details
    #
    # @example
    #   format_request_details
    #   # => "192.0.2.1; GET /path?query=string; Proxy[X-Forwarded-For: 203.0.113.195 Remote-Addr: 192.0.2.1]"
    def format_request_details(header_prefix: nil)
      header_details = collect_proxy_headers(header_prefix: header_prefix)

      details = [
        client_ipaddress,
        "#{request_method} #{env['PATH_INFO']}?#{env['QUERY_STRING']}",
        "Proxy[#{header_details}]",
      ]

      details.join('; ')
    end

    # Check if user agent matches blocked patterns
    #
    # This method checks if the current request's user agent string
    # matches any of the provided blocked agent patterns.
    #
    # @param blocked_agents [Array<String, Symbol, Regexp>] Patterns to check against
    # @return [Boolean] true if user agent is allowed, false if blocked
    #
    # @example
    #   blocked_user_agent?([:bot, :crawler, 'BadAgent'])
    #   # => false if user agent contains 'bot', 'crawler', or 'BadAgent'
    def blocked_user_agent?(blocked_agents: [])
      return true if blocked_agents.empty?

      user_agent_string = user_agent.to_s.downcase
      return true if user_agent_string.empty?

      blocked_agents.flatten.any? do |agent|
        case agent
        when Regexp
          user_agent_string.match?(agent)
        else
          user_agent_string.include?(agent.to_s.downcase)
        end
      end
    end
  end
end
