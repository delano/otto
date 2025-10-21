# lib/otto/helpers/request.rb

require_relative 'base'

class Otto
  # Request helper methods providing HTTP request handling utilities
  module RequestHelpers
    include Otto::BaseHelpers

    def user_agent
      env['HTTP_USER_AGENT']
    end

    # NOTE: We do NOT override Rack::Request#ip
    #
    # IPPrivacyMiddleware masks both REMOTE_ADDR and X-Forwarded-For headers,
    # so Rack's native ip resolution logic works correctly with masked values.
    # This allows Rack to handle proxy scenarios (trusted proxies, header parsing)
    # while still returning privacy-safe masked IPs.
    #
    # If you need the masked IP explicitly, use:
    #   req.masked_ip  # => '192.168.1.0' or nil if privacy disabled
    #
    # If you need the geo country:
    #   req.geo_country  # => 'US' or nil
    #
    # If you need the full privacy fingerprint:
    #   req.redacted_fingerprint  # => RedactedFingerprint object or nil

    # Get the privacy-safe fingerprint for this request
    #
    # Returns nil if IP privacy is disabled. The fingerprint contains
    # anonymized request information suitable for logging and analytics.
    #
    # @return [Otto::Privacy::RedactedFingerprint, nil] Privacy-safe fingerprint
    # @example
    #   fingerprint = req.redacted_fingerprint
    #   fingerprint.masked_ip    # => '192.168.1.0'
    #   fingerprint.country      # => 'US'
    def redacted_fingerprint
      env['otto.redacted_fingerprint']
    end

    # Get the geo-location country code for the request
    #
    # Returns ISO 3166-1 alpha-2 country code or 'XX' for unknown.
    # Only available when IP privacy is enabled (default).
    #
    # @return [String, nil] Country code or nil if privacy disabled
    # @example
    #   req.geo_country  # => 'US'
    def geo_country
      redacted_fingerprint&.country || env['otto.geo_country']
    end

    # Get anonymized user agent string
    #
    # Returns user agent with version numbers stripped for privacy.
    # When privacy is enabled (default), env['HTTP_USER_AGENT'] is already
    # anonymized by IPPrivacyMiddleware, so this just returns that value.
    # When privacy is disabled, returns the raw user agent.
    #
    # @return [String, nil] Anonymized (or raw if privacy disabled) user agent
    # @example
    #   req.anonymized_user_agent
    #   # => 'Mozilla/X.X (Windows NT X.X; Win64; x64) AppleWebKit/X.X'
    # @deprecated Use env['HTTP_USER_AGENT'] directly (already anonymized when privacy enabled)
    def anonymized_user_agent
      user_agent
    end

    # Get masked IP address
    #
    # Returns privacy-safe masked IP. When privacy is enabled (default),
    # this returns the masked version. When disabled, returns original IP.
    #
    # @return [String, nil] Masked or original IP address
    # @example
    #   req.masked_ip  # => '192.168.1.0'
    def masked_ip
      env['otto.masked_ip'] || env['REMOTE_ADDR']
    end

    # Get hashed IP for session correlation
    #
    # Returns daily-rotating hash of the IP address, allowing session
    # tracking without storing the original IP. Only available when
    # IP privacy is enabled (default).
    #
    # @return [String, nil] Hexadecimal hash string or nil
    # @example
    #   req.hashed_ip  # => 'a3f8b2c4d5e6f7...'
    def hashed_ip
      redacted_fingerprint&.hashed_ip || env['otto.hashed_ip']
    end

    def client_ipaddress
      remote_addr = env['REMOTE_ADDR']

      # If we don't have a security config or trusted proxies, use direct connection
      return validate_ip_address(remote_addr) if !otto_security_config || !trusted_proxy?(remote_addr)

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

      # Check both IP and server name for comprehensive localhost detection
      server_name        = env['SERVER_NAME']
      local_server_names = ['localhost', '127.0.0.1', '0.0.0.0']

      local_or_private_ip?(ip) && local_server_names.include?(server_name)
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
        /\A10\./, # 10.0.0.0/8
        /\A172\.(1[6-9]|2[0-9]|3[01])\./, # 172.16.0.0/12
        /\A192\.168\./,              # 192.168.0.0/16
        /\A169\.254\./,              # 169.254.0.0/16 (link-local)
        /\A224\./,                   # 224.0.0.0/4 (multicast)
        /\A0\./, # 0.0.0.0/8
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
        prefix_keys = env.keys.select { _1.upcase.start_with?("HTTP_#{header_prefix.upcase}") }
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
    #
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

    # Build application path by joining path segments
    #
    # This method safely joins multiple path segments, handling
    # duplicate slashes and ensuring proper path formatting.
    # Includes the script name (mount point) as the first segment.
    #
    # @param paths [Array<String>] Path segments to join
    # @return [String] Properly formatted path
    #
    # @example
    #   app_path('api', 'v1', 'users')
    #   # => "/myapp/api/v1/users"
    #
    # @example
    #   app_path(['admin', 'settings'])
    #   # => "/myapp/admin/settings"
    def app_path(*paths)
      paths = paths.flatten.compact
      paths.unshift(env['SCRIPT_NAME']) if env['SCRIPT_NAME']
      paths.join('/').gsub('//', '/')
    end

    # Set the locale for the request based on multiple sources
    #
    # This method determines the locale to be used for the request by checking
    # the following sources in order of precedence:
    # 1. The locale parameter passed to the method
    # 2. The locale query parameter in the request
    # 3. The user's saved locale preference (if provided)
    # 4. The rack.locale environment variable
    #
    # If a valid locale is found, it's stored in the request environment.
    # If no valid locale is found, the default locale is used.
    #
    # @param locale [String, nil] The locale to use, if specified
    # @param opts [Hash] Configuration options
    # @option opts [Hash] :available_locales Hash of available locales to validate against (required unless configured at Otto level)
    # @option opts [String] :default_locale Default locale to use as fallback (required unless configured at Otto level)
    # @option opts [String, nil] :preferred_locale User's saved locale preference
    # @option opts [String] :locale_env_key Environment key to store the locale (default: 'locale')
    # @option opts [Boolean] :debug Enable debug logging for locale selection
    # @return [String] The selected locale
    #
    # @example Basic usage
    #   check_locale!(
    #     available_locales: { 'en' => 'English', 'es' => 'Spanish' },
    #     default_locale: 'en'
    #   )
    #   # => 'en'
    #
    # @example With user preference
    #   check_locale!(nil, {
    #     available_locales: { 'en' => 'English', 'es' => 'Spanish' },
    #     default_locale: 'en',
    #     preferred_locale: 'es'
    #   })
    #   # => 'es'
    #
    # @example Using Otto-level configuration
    #   # Otto configured with: Otto.new(routes, { locale_config: { available: {...}, default: 'en' } })
    #   check_locale!('es')  # Uses Otto's config automatically
    #   # => 'es'
    #
    def check_locale!(locale = nil, opts = {})
      # Get configuration from options, Otto config, or environment (in that order)
      otto_config = env['otto.locale_config']

      available_locales = opts[:available_locales] ||
                          otto_config&.dig(:available_locales) ||
                          env['otto.available_locales']
      default_locale    = opts[:default_locale] ||
                          otto_config&.dig(:default_locale) ||
                          env['otto.default_locale']
      preferred_locale  = opts[:preferred_locale]
      locale_env_key    = opts[:locale_env_key] || 'locale'
      debug_enabled     = opts[:debug] || false

      # Guard clause - required configuration must be present
      unless available_locales.is_a?(Hash) && !available_locales.empty? && default_locale && available_locales.key?(default_locale)
        raise ArgumentError,
              'available_locales must be a non-empty Hash and include default_locale (provide via opts or Otto configuration)'
      end

      # Check sources in order of precedence
      locale ||= env['rack.request.query_hash'] && env['rack.request.query_hash']['locale']
      locale ||= preferred_locale if preferred_locale
      locale ||= (env['rack.locale'] || []).first

      # Validate locale against available translations
      have_translations = locale && available_locales.key?(locale.to_s)

      # Debug logging if enabled
      if debug_enabled && defined?(Otto.logger)
        message = format(
          '[check_locale!] sources[param=%s query=%s user=%s rack=%s] valid=%s',
          locale,
          env.dig('rack.request.query_hash', 'locale'),
          preferred_locale,
          (env['rack.locale'] || []).first,
          have_translations
        )
        Otto.logger.debug message
      end

      # Set the locale in request environment
      selected_locale = have_translations ? locale : default_locale
      env[locale_env_key] = selected_locale

      selected_locale
    end
  end
end
