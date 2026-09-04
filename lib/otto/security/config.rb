# lib/otto/security/config.rb
#
# frozen_string_literal: true

require 'securerandom'
require 'digest'
require 'openssl'
require 'ipaddr'
require 'rack/request'
require_relative '../core/freezable'
require_relative 'csp/policy'

class Otto
  module Security
    # Security configuration for Otto applications
    #
    # This class manages all security-related settings including CSRF protection,
    # input validation, trusted proxies, and security headers. Security features
    # are disabled by default for backward compatibility.
    #
    # @example Basic usage
    #   config = Otto::Security::Config.new
    #   config.enable_csrf_protection!
    #   config.add_trusted_proxy('10.0.0.0/8')
    #
    # @example Custom limits
    #   config = Otto::Security::Config.new
    #   config.max_request_size = 5 * 1024 * 1024  # 5MB
    #   config.max_param_depth = 16
    class Config
      include Otto::Core::Freezable

      # Error raised when the two mutually-exclusive trusted-proxy resolution
      # modes are configured together: CIDR-walk (enumerated #trusted_proxies)
      # and count-based depth (#trusted_proxy_depth >= 1).
      PROXY_MODE_CONFLICT_MESSAGE = <<~MSG.gsub(/\s+/, ' ').strip.freeze
        Cannot configure both trusted_proxies (CIDR filter mode) and
        trusted_proxy_depth >= 1 (count mode). Enumerate proxy CIDRs OR set a
        hop count, not both.
      MSG

      # Error raised when an app-configured trusted geo header (ip_privacy
      # geo_header) is combined with count-based depth mode. Geo headers are
      # honored only for peers matching enumerated trusted_proxies CIDRs
      # (geo_headers_trusted? gates on trusted_proxies_configured?) — a hop
      # trusted by count cannot be verified as the geo-setting CDN — so a
      # geo_header configured alongside a depth could never be consulted.
      # Failing loud at config time replaces a silent database/'**' fallback
      # at request time.
      GEO_HEADER_DEPTH_CONFLICT_MESSAGE = <<~MSG.gsub(/\s+/, ' ').strip.freeze
        Cannot configure a trusted geo header (ip_privacy geo_header) together
        with trusted_proxy_depth (count mode): geo headers are only honored
        for peers matching enumerated trusted_proxies CIDRs, so the header
        would be silently ignored. Use filter mode (add_trusted_proxy) for
        header-based geo, or drop geo_header and use database-backed geo
        (geo_db_path or geo_db_reader).
      MSG

      # Forwarded-header sources depth mode (#trusted_proxy_depth) can count
      # hops from: X-Forwarded-For (default), the RFC 7239 Forwarded header, or
      # Both (Forwarded when present, else X-Forwarded-For). Mirrors
      # OneTimeSecret's site.network.trusted_proxy.header. Only consulted in
      # depth mode; CIDR-walk is unaffected.
      TRUSTED_PROXY_HEADERS = %w[X-Forwarded-For Forwarded Both].freeze

      # Rack uses one process-global priority for forwarded host, port, scheme,
      # and IP resolution. Keep it aligned with Otto's configured forwarding
      # family so the two request views cannot silently disagree.
      RACK_REQUEST = ::Rack::Request
      DEFAULT_RACK_FORWARDED_PRIORITY = RACK_REQUEST.forwarded_priority.dup.freeze
      RACK_FORWARDED_PRIORITIES = {
        'X-Forwarded-For' => [:x_forwarded].freeze,
        'Forwarded' => [:forwarded].freeze,
        'Both' => %i[forwarded x_forwarded].freeze,
      }.freeze
      DEFAULT_TRUSTED_PROXY_HEADER = 'X-Forwarded-For'
      FORWARDING_FAMILY_CONFLICT_MESSAGE = <<~MSG.gsub(/\s+/, ' ').strip.freeze
        Cannot use forwarding family %s (trusted_proxy_header) because another
        Otto application in this process already uses %s. Rack's forwarded
        host, port, scheme, and IP policy is process-global, so every Otto
        application in one process that resolves proxied requests must use the
        same forwarding family.
      MSG
      # Error raised when a non-default trusted_proxy_header is combined with
      # CIDR filter mode. Otto's CIDR-walk resolves the client IP from
      # X-Forwarded-For only, while trusted_proxy_header also pins Rack's
      # forwarding family; honoring 'Forwarded' or 'Both' there would make Rack
      # read a header Otto ignores, recreating the disagreement the pin exists
      # to close.
      FORWARDED_HEADER_CIDR_CONFLICT_MESSAGE = <<~MSG.gsub(/\s+/, ' ').strip.freeze
        Cannot configure trusted_proxy_header 'Forwarded' or 'Both' together
        with trusted_proxies (CIDR filter mode): CIDR-walk resolves client IPs
        from X-Forwarded-For only. Use trusted_proxy_depth (count mode) to
        read the RFC 7239 Forwarded header.
      MSG

      # Eager so the first two concurrent Otto.new calls cannot race on
      # creating the lock itself.
      RACK_FORWARDING_MUTEX = Mutex.new
      private_constant :RACK_FORWARDING_MUTEX

      class << self
        # Pin Rack's process-global forwarding family to Otto's.
        #
        # Rack::Request.forwarded_priority is one setting per process, so two
        # Otto applications that commit to different families cannot coexist:
        # the later commitment raises. A config commits (claim: true) when the
        # operator sets trusted_proxy_header or configures proxy trust at all
        # (trusted_proxies or a depth): an app that resolves proxied requests
        # from X-Forwarded-For depends on Rack reading the same family, even
        # though it never named one. A config may revise its own commitment
        # before it freezes, as long as no other config has committed to the
        # previous family.
        #
        # A config with no proxy trust and no explicit header (claim: false, a
        # bare Otto.new) is indifferent: it pins Rack to the default only while
        # nothing is committed and otherwise defers, so a no-options sub-mount
        # constructed first cannot block a later `trusted_proxy_header:
        # 'Forwarded'` with an error naming a family nobody chose.
        #
        # Committed configs are held strongly on purpose. A weak registry made
        # the conflict check depend on whether the earlier config had been
        # garbage collected, so boot order and GC timing decided whether the
        # app raised. Otto#initialize releases the claim when construction
        # fails after the config committed (see .release_rack_forwarding_family!).
        #
        # @param config [Otto::Security::Config] the config applying the family
        # @param header [String] canonical TRUSTED_PROXY_HEADERS value
        # @param claim [Boolean] whether this config depends on the family
        # @raise [ArgumentError] on a conflict with another committed config
        def apply_rack_forwarding_family!(config, header, claim: true)
          RACK_FORWARDING_MUTEX.synchronize do
            if claim
              committed = rack_forwarding_family
              if committed && committed != header &&
                 rack_forwarding_owners.each_key.any? { |owner| !owner.equal?(config) }
                raise ArgumentError, format(FORWARDING_FAMILY_CONFLICT_MESSAGE, header, committed)
              end

              rack_forwarding_owners[config] = true
              @rack_forwarding_family = header
            elsif rack_forwarding_family
              # A committed choice already governs Rack; the default defers.
              next
            end

            RACK_REQUEST.forwarded_priority = RACK_FORWARDED_PRIORITIES.fetch(header).dup
          end
        end

        # Withdraw a config's commitment, e.g. when Otto.new fails after the
        # config committed. Rack's priority is left as-is: it is either still
        # backed by another owner or will be re-pinned by the next app.
        #
        # @param config [Otto::Security::Config]
        # @return [void]
        def release_rack_forwarding_family!(config)
          RACK_FORWARDING_MUTEX.synchronize do
            rack_forwarding_owners.delete(config)
            @rack_forwarding_family = nil if rack_forwarding_owners.empty?
          end
        end

        # The forwarding family explicitly committed for this process, or nil.
        #
        # @return [String, nil]
        attr_reader :rack_forwarding_family

        # Clear process-global forwarding state between isolated RSpec examples.
        #
        # @api private
        def reset_rack_forwarding_family_for_testing!
          raise 'reset_rack_forwarding_family_for_testing! is only available in RSpec test environment' unless defined?(RSpec)

          RACK_FORWARDING_MUTEX.synchronize do
            @rack_forwarding_owners = nil
            @rack_forwarding_family = nil
            RACK_REQUEST.forwarded_priority = DEFAULT_RACK_FORWARDED_PRIORITY.dup
          end
        end

        private

        # Identity-keyed set of configs committed to the family.
        def rack_forwarding_owners
          @rack_forwarding_owners ||= {}.compare_by_identity
        end
      end

      # Endpoint group name shared by the CSP `report-to` directive and the
      # `Reporting-Endpoints` response header (modern Reporting API). Browsers
      # match the directive's group to the header's key, so both must agree.
      # Aliases {Otto::Security::CSP::Policy::REPORTING_GROUP} — the one source
      # the policy builder uses — so the header and the directive cannot drift.
      CSP_REPORTING_GROUP = Otto::Security::CSP::Policy::REPORTING_GROUP

      # Error raised when CSRF protection is enabled in production without an
      # explicitly configured secret. A randomly-generated per-process secret
      # silently breaks token verification across workers and restarts, so we
      # refuse it in production rather than serve intermittently-failing tokens.
      CSRF_SECRET_REQUIRED_MESSAGE = <<~MSG.gsub(/\s+/, ' ').strip.freeze
        CSRF protection is enabled in production without a configured secret.
        Set OTTO_CSRF_SECRET (or config.csrf_secret=) to a stable random value
        (e.g. SecureRandom.hex(32)); a per-process random secret is not valid
        across workers or restarts.
      MSG

      attr_accessor :input_validation, :max_param_depth, :csrf_token_key,
                    :rate_limiting_config, :csrf_session_key, :max_request_size,
                    :max_param_keys

      attr_reader :csrf_protection,  :csrf_header_key,
                  :trusted_proxies, :require_secure_cookies,
                  :security_headers,
                  :csp_nonce_enabled, :debug_csp, :mcp_auth, :csp_nonce_key,
                  :ip_privacy_config, :trusted_proxy_depth, :trusted_proxy_header,
                  :csp_report_uri, :csp_report_to_url, :csp_violation_callback,
                  :csp_directive_overrides, :csp_request_extras_enabled

      # Initialize security configuration with safe defaults
      #
      # All security features are disabled by default to maintain backward
      # compatibility with existing Otto applications.
      def initialize
        @csrf_protection        = false
        @csrf_token_key         = '_csrf_token'
        @csrf_header_key        = 'HTTP_X_CSRF_TOKEN'
        @csrf_session_key       = '_csrf_session_id'
        @max_request_size       = 10 * 1024 * 1024 # 10MB
        @max_param_depth        = 32
        @max_param_keys         = 64
        @trusted_proxies        = []
        @trusted_proxy_matchers = []
        @trusted_proxy_depth    = nil
        @trusted_proxy_header   = DEFAULT_TRUSTED_PROXY_HEADER
        @require_secure_cookies = false
        @security_headers       = default_security_headers
        @input_validation       = true
        @csp_nonce_enabled      = false
        @debug_csp              = false
        @csp_nonce_key          = 'otto.nonce'
        @csp_policy             = nil
        @csp_report_uri         = nil
        @csp_report_to_url      = nil
        @csp_violation_callback = nil
        @csp_directive_overrides = {}
        @csp_request_extras_enabled = false
        @csp_script_src_override_warned = false
        @rate_limiting_config   = { custom_rules: {} }
        @ip_privacy_config      = Otto::Privacy::Config.new

        configured_secret      = ENV.fetch('OTTO_CSRF_SECRET', nil)
        @csrf_secret_generated = configured_secret.nil? || configured_secret.empty?
        @csrf_secret           = @csrf_secret_generated ? SecureRandom.hex(32) : configured_secret
      end

      # Enable CSRF (Cross-Site Request Forgery) protection
      #
      # When enabled, Otto will:
      # - Generate CSRF tokens for safe HTTP methods (GET, HEAD, OPTIONS, TRACE)
      # - Validate CSRF tokens for unsafe methods (POST, PUT, DELETE, PATCH)
      # - Automatically inject CSRF meta tags into HTML responses
      # - Provide helper methods for forms and AJAX requests
      #
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      def enable_csrf_protection!
        ensure_not_frozen!

        @csrf_protection = true
      end

      # Disable CSRF protection
      #
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      def disable_csrf_protection!
        ensure_not_frozen!

        @csrf_protection = false
      end

      # Check if CSRF protection is currently enabled
      #
      # @return [Boolean] true if CSRF protection is enabled
      def csrf_enabled?
        @csrf_protection
      end

      # Add a trusted proxy server for accurate client IP detection
      #
      # Only requests from trusted proxies will have their X-Forwarded-For
      # and similar headers honored for IP detection. This prevents IP spoofing
      # from untrusted sources.
      #
      # @param proxy [String, Array] IP address, CIDR range, or array of addresses
      # @raise [ArgumentError] if proxy is not a String or Array
      # @raise [FrozenError] if configuration is frozen
      # @return [void]
      #
      # @example Add single proxy
      #   config.add_trusted_proxy('10.0.0.1')
      #
      # @example Add CIDR range
      #   config.add_trusted_proxy('192.168.0.0/16')
      #
      # @example Add multiple proxies
      #   config.add_trusted_proxy(['10.0.0.1', '172.16.0.0/12'])
      def add_trusted_proxy(proxy)
        ensure_not_frozen!
        # CIDR-walk and count-based depth are mutually exclusive. Catch the
        # conflict eagerly here (and in #trusted_proxy_depth=) so it surfaces at
        # configuration time, not only at freeze (which the test harness skips).
        raise ArgumentError, PROXY_MODE_CONFLICT_MESSAGE if trusted_proxy_depth_mode?
        # Same pattern for header-then-proxies; proxies-then-header is caught
        # in #trusted_proxy_header=.
        raise ArgumentError, FORWARDED_HEADER_CIDR_CONFLICT_MESSAGE unless default_trusted_proxy_header?

        case proxy
        when String, Regexp
          @trusted_proxies << proxy
          @trusted_proxy_matchers << register_proxy_matcher(proxy)
        when Array
          proxy.each { |entry| @trusted_proxy_matchers << register_proxy_matcher(entry) }
          @trusted_proxies.concat(proxy)
        else
          raise ArgumentError, 'Proxy must be a String, Regexp, or Array'
        end
      end

      # Check if an IP address is from a trusted proxy
      #
      # String entries that parse as an IP or CIDR range are matched with
      # proper IPAddr containment (IPv4 and IPv6). Entries that are not valid
      # IPs (e.g. a bare prefix like '172.16.') fall back to the legacy
      # exact/prefix string match for backward compatibility. Regexp entries
      # are matched against the raw IP string.
      #
      # Proxy entries are parsed once at registration (see #add_trusted_proxy)
      # into @trusted_proxy_matchers, so this never re-parses per request.
      #
      # @param ip [String] IP address to check
      # @return [Boolean] true if the IP is from a trusted proxy
      def trusted_proxy?(ip)
        return false if @trusted_proxy_matchers.empty? || ip.nil? || ip.empty?

        # Fold IPv4-mapped IPv6 (::ffff:a.b.c.d) to plain IPv4 so a dual-stack
        # peer presented in mapped form still matches an IPv4 proxy entry.
        client = parse_ipaddr(ip)&.native

        @trusted_proxy_matchers.any? do |entry, range|
          if range
            # Pre-parsed IP/CIDR entry -> proper containment
            client && ip_in_range?(range, client)
          elsif entry.is_a?(Regexp)
            entry.match?(ip)
          elsif entry.is_a?(String)
            # Legacy non-IP entry (e.g. '172.16.') -> exact/prefix match
            ip == entry || ip.start_with?(entry)
          else
            false
          end
        end
      end

      # Whether any trusted-proxy IP/CIDR/Regexp matchers are configured.
      #
      # This mirrors {#trusted_proxy?}, which consults the same matcher list.
      # It deliberately EXCLUDES count-based depth mode: depth grants the peer
      # blanket trust for otto.via_trusted_proxy (#226), but it cannot verify
      # that the hop is a geo-setting CDN, so header-based geo stays gated on
      # enumerated matchers only. Used to gate geo-header trust.
      #
      # @return [Boolean] true when at least one trusted-proxy matcher exists
      def trusted_proxies_configured?
        @trusted_proxy_matchers.any?
      end

      # Whether ANY proxy-trust mode is configured — CIDR matchers (filter
      # mode) or count-based depth. This is the gate for writing
      # env['otto.via_trusted_proxy'] at all: when neither mode is configured
      # the key is left ABSENT (tri-state contract), so downstream consumers
      # can distinguish "operator configured trust and this peer failed it"
      # (false) from "no proxy trust configured" (absent) and apply their own
      # legacy heuristics only in the latter case.
      #
      # @return [Boolean] true when filter or depth mode is configured
      def proxy_trust_configured?
        trusted_proxies_configured? || trusted_proxy_depth_mode?
      end

      # Whether count-based ("trust the last N hops") proxy resolution is active.
      #
      # When true, Otto::Utils.resolve_client_ip ignores trusted-proxy CIDRs and
      # instead trusts a fixed number of hops from the right of the forwarded
      # chain (Express `trust proxy = N`). This is the only sound model for
      # non-enumerable proxy tiers (Fly, cloud load balancers, dynamic reverse
      # proxies) whose addresses cannot be listed as CIDRs.
      #
      # @return [Boolean] true when trusted_proxy_depth is an Integer >= 1
      def trusted_proxy_depth_mode?
        @trusted_proxy_depth.is_a?(Integer) && @trusted_proxy_depth >= 1
      end

      # Set the count-based trusted-proxy depth ("trust the last N hops").
      #
      # Validates eagerly so a misconfiguration fails at assignment rather than
      # only at freeze (which the test harness skips): the value must be a
      # non-negative Integer or nil, and the mode is mutually exclusive with
      # CIDR-walk (trusted_proxies). nil/0 disable depth mode.
      #
      # @param depth [Integer, nil] number of trusted hops (nil/0 disables depth mode)
      # @raise [FrozenError] if configuration is frozen
      # @raise [ArgumentError] if depth is non-integer/negative, or if
      #   trusted_proxies are already configured and depth >= 1
      def trusted_proxy_depth=(depth)
        ensure_not_frozen!

        validate_trusted_proxy_depth!(depth)
        raise ArgumentError, PROXY_MODE_CONFLICT_MESSAGE if depth.to_i >= 1 && @trusted_proxies.any?
        # Depth-then-geo assignment order is caught by configure_ip_privacy;
        # this catches geo-then-depth so both orders fail eagerly.
        raise ArgumentError, GEO_HEADER_DEPTH_CONFLICT_MESSAGE if depth.to_i >= 1 && @ip_privacy_config&.geo_header

        @trusted_proxy_depth = depth
      end

      # Select which forwarded header family Otto and Rack read from:
      # 'X-Forwarded-For' (default), 'Forwarded' (RFC 7239), or 'Both'
      # (Forwarded when present, else X-Forwarded-For).
      #
      # Otto consults the value in count-based depth mode
      # (#trusted_proxy_depth_mode?) to pick the chain it counts hops from.
      # CIDR-walk always resolves from X-Forwarded-For / X-Real-IP /
      # X-Client-IP, so 'Forwarded' and 'Both' are rejected once trusted_proxies
      # are configured (and vice versa in #add_trusted_proxy).
      #
      # The value is matched case-insensitively (surrounding whitespace ignored)
      # and stored in its canonical spelling, so a hand-edited config can write
      # `forwarded` or `both` without surprise. A genuinely unrecognized value
      # fails loud at assignment (rather than silently resolving from the wrong
      # header, the way a permissive default would), so a typo surfaces at config
      # time instead of as subtly-wrong client IPs at request time.
      #
      # Applying this setting also pins Rack::Request.forwarded_priority to the
      # corresponding family. Rack exposes that policy process-wide, so every
      # Otto application in one process must agree; see
      # Config.apply_rack_forwarding_family!.
      #
      # @param header [String] one of TRUSTED_PROXY_HEADERS (case-insensitive)
      # @raise [FrozenError] if configuration is frozen
      # @raise [ArgumentError] if header is not a recognized value, conflicts
      #   with configured trusted_proxies, or conflicts with another Otto
      #   application's explicit choice in this process
      def trusted_proxy_header=(header)
        ensure_not_frozen!

        canonical_header = canonicalize_trusted_proxy_header(header)
        cidr_conflict = canonical_header != DEFAULT_TRUSTED_PROXY_HEADER && @trusted_proxies.any?
        raise ArgumentError, FORWARDED_HEADER_CIDR_CONFLICT_MESSAGE if cidr_conflict

        self.class.apply_rack_forwarding_family!(self, canonical_header)
        @trusted_proxy_header = canonical_header
      end

      # Align Rack's forwarding family with this config's current value. Used by
      # Otto.new when no trusted_proxy_header option was given, so a bare app
      # still pins Rack to X-Forwarded-For instead of inheriting Rack's
      # process-global default. The pin is a commitment only when this config
      # already depends on the family (proxy trust configured); otherwise it
      # defers to any commitment made elsewhere in the process.
      #
      # @raise [FrozenError] if configuration is frozen
      # @return [void]
      def apply_default_rack_forwarding_family!
        ensure_not_frozen!

        self.class.apply_rack_forwarding_family!(self, @trusted_proxy_header, claim: proxy_trust_configured?)
      end

      # Commit this config's current family process-wide once it depends on
      # one (proxy trust configured). Not called from the trusted_proxies /
      # depth setters themselves, so assignment order relative to
      # trusted_proxy_header= cannot raise a spurious conflict; instead it runs
      # at the configuration boundaries: Otto.new
      # (#apply_default_rack_forwarding_family!), Configurator#configure, and
      # freeze (#validate_trusted_proxy_config!). A no-op without proxy trust.
      #
      # @raise [ArgumentError] on a conflict with another committed config
      # @return [void]
      def commit_rack_forwarding_family!
        ensure_not_frozen!
        return unless proxy_trust_configured?

        self.class.apply_rack_forwarding_family!(self, @trusted_proxy_header)
      end

      # Whether trusted_proxy_header is the X-Forwarded-For default.
      #
      # @return [Boolean]
      def default_trusted_proxy_header?
        @trusted_proxy_header == DEFAULT_TRUSTED_PROXY_HEADER
      end

      # Validate that a request size is within acceptable limits
      #
      # @param content_length [String, Integer, nil] Content-Length header value
      # @raise [Otto::Security::RequestTooLargeError] if request exceeds maximum size
      # @return [Boolean] true if request size is acceptable
      def validate_request_size(content_length)
        return true if content_length.nil?

        size = content_length.to_i
        if size > @max_request_size
          raise Otto::Security::RequestTooLargeError,
                "Request size #{size} exceeds maximum #{@max_request_size}"
        end
        true
      end

      # Set the server-side secret used to sign (HMAC) CSRF tokens. Set this to
      # a stable value (e.g. ENV['OTTO_CSRF_SECRET']) in multi-process or
      # multi-host deployments so tokens stay valid across workers and restarts.
      #
      # Write-only by design: the signing key has no public reader, so it is not
      # exposed to inspection/logging/serialization via the config object.
      def csrf_secret=(secret)
        ensure_not_frozen!

        @csrf_secret           = secret
        @csrf_secret_generated = false
      end

      # Generate a CSRF token bound to the given session id and signed (HMAC-SHA256)
      # with the server-side secret, so tokens cannot be self-minted and are not
      # valid across sessions. A session binding is REQUIRED.
      def generate_csrf_token(session_id = nil)
        binding_id = session_id.to_s
        raise ArgumentError, 'CSRF token generation requires a session binding' if binding_id.empty?

        reject_generated_secret_in_production!
        warn_generated_csrf_secret
        token = SecureRandom.hex(32)
        "#{token}:#{sign_csrf_token(binding_id, token)}"
      end

      # Verify a CSRF token against its session binding using a constant-time
      # comparison. Returns false (never raises) for blank/malformed input.
      def verify_csrf_token(token, session_id = nil)
        return false if token.nil? || token.empty?

        binding_id = session_id.to_s
        return false if binding_id.empty?

        token_part, signature = token.split(':', 2)
        return false if token_part.nil? || signature.nil?

        expected_signature = sign_csrf_token(binding_id, token_part)
        secure_compare(signature, expected_signature)
      end

      # Enable HTTP Strict Transport Security (HSTS) header
      #
      # HSTS forces browsers to use HTTPS for all future requests to this domain.
      # WARNING: This can make your domain inaccessible if HTTPS is not properly
      # configured. Only enable this when you're certain HTTPS is working correctly.
      #
      # @param max_age [Integer] Maximum age in seconds (default: 1 year)
      # @param include_subdomains [Boolean] Apply to all subdomains (default: true)
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      def enable_hsts!(max_age: 31_536_000, include_subdomains: true)
        ensure_not_frozen!

        hsts_value                                     = "max-age=#{max_age}"
        hsts_value                                    += '; includeSubDomains' if include_subdomains
        @security_headers['strict-transport-security'] = hsts_value
      end

      # Enable Content Security Policy (CSP) header
      #
      # CSP helps prevent XSS attacks by controlling which resources can be loaded.
      # The default policy only allows resources from the same origin.
      #
      # @param policy [String] CSP policy string (default: "default-src 'self'")
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      #
      # @example Custom policy
      #   config.enable_csp!("default-src 'self'; script-src 'self' 'unsafe-inline'")
      def enable_csp!(policy = "default-src 'self'")
        ensure_not_frozen!

        @csp_policy = policy
        @security_headers['content-security-policy'] = build_static_csp(policy)
      end

      # Enable Content Security Policy (CSP) with nonce support
      #
      # This enables dynamic CSP header generation with nonces for enhanced security.
      # Unlike enable_csp!, this doesn't set a static policy but enables the response
      # helper to generate CSP headers with nonces on a per-request basis.
      #
      # Per-directive overrides may be supplied to customize the emitted nonce
      # policy without vendoring the gem. They merge into Otto's base directive
      # sets ({Otto::Security::CSP::Policy.development_directives} /
      # {Otto::Security::CSP::Policy.production_directives}): a matching directive
      # is replaced in place, a new directive is appended, and a nil/false value
      # removes a directive. See {#csp_directive_overrides=} for the accepted
      # shape.
      #
      # @param debug [Boolean] Enable debug logging for CSP headers (default: false)
      # @param directives [Hash] per-directive overrides merged into the base set
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      #
      # @example
      #   config.enable_csp_with_nonce!(debug: true)
      #
      # @example Restore data: workers (blob: is the default worker-src token)
      #   config.enable_csp_with_nonce!(directives: { 'worker-src' => "'self' data: blob:" })
      def enable_csp_with_nonce!(debug: false, directives: {})
        ensure_not_frozen!

        # Apply overrides before toggling state so a bad +directives+ argument
        # raises without leaving the config half-updated (nonce enabled but
        # overrides not merged).
        merge_csp_directives(directives) unless directives.nil? || directives.empty?
        @csp_nonce_enabled = true
        @debug_csp         = debug
      end

      # Replace the per-directive overrides applied to the nonce CSP policy.
      #
      # Overrides merge into Otto's base directive sets when
      # {#generate_nonce_csp} builds the policy, so a consuming app can adjust
      # ANY directive rather than only `report-uri`/`report-to`. Keys are
      # directive names (String or Symbol, matched case-insensitively); values
      # are the source list as a String (`"'self' blob:"`) or Array
      # (`%w['self' blob:]`), or nil/false to REMOVE the directive.
      #
      # Keys are normalized on store (lowercased, hyphenated) via
      # {Otto::Security::CSP::Policy.normalize_overrides}, so the stored hash
      # never accumulates logically-identical entries under different key styles
      # (`'WORKER-SRC'` and `:worker_src` both read back as `'worker-src'`).
      #
      # @note Overriding `script-src` while nonce mode is enabled disables
      #   nonce-based script protection: the per-request nonce cannot be
      #   included in a static override, so it is stripped from the emitted
      #   header. A warning is logged when a `script-src` override is stored.
      #   See {Otto::Security::CSP::Policy.merge_directives}.
      #
      # @param overrides [Hash] directive name => source list / nil
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      #
      # @example
      #   config.csp_directive_overrides = { 'worker-src' => "'self' data: blob:" }
      def csp_directive_overrides=(overrides)
        ensure_not_frozen!

        normalized = Otto::Security::CSP::Policy.normalize_overrides(overrides || {})
        warn_if_script_src_overridden(normalized)
        @csp_directive_overrides = normalized
      end

      # Merge additional per-directive overrides into the existing set, leaving
      # untouched any directive not named in +overrides+ (last write wins for a
      # repeated directive). Use this to accumulate overrides incrementally;
      # use {#csp_directive_overrides=} to replace them wholesale.
      #
      # @param overrides [Hash] directive name => source list / nil
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      def merge_csp_directives(overrides)
        ensure_not_frozen!

        normalized = Otto::Security::CSP::Policy.normalize_overrides(overrides || {})
        warn_if_script_src_overridden(normalized)
        @csp_directive_overrides = @csp_directive_overrides.merge(normalized)
      end

      # Disable CSP nonce support
      #
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      def disable_csp_nonce!
        ensure_not_frozen!

        @csp_nonce_enabled = false
      end

      # Check if CSP nonce support is enabled
      #
      # @return [Boolean] true if CSP nonce support is enabled
      def csp_nonce_enabled?
        @csp_nonce_enabled
      end

      # Enable the request-scoped CSP directive extras channel (delano/otto#243)
      #
      # Off by default: `env['otto.csp.extra_directives']` is a write surface
      # that ANY middleware in the Rack stack can reach — a lower-trust
      # position than boot code — so the channel does not exist until the app
      # explicitly opts in here. Until then the Writer ignores the env key
      # entirely (no sanitize work, no logs).
      #
      # With the channel enabled, a handler (or middleware) can widen
      # directives with values only known at request time by writing a hash of
      # directive name => additional origin tokens to the env before the
      # response is finalized. Extras are additive-only and sanitized
      # defensively; see {Otto::Security::CSP::RequestExtras}.
      #
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      #
      # @example At boot, alongside nonce CSP
      #   config.enable_csp_with_nonce!
      #   config.enable_csp_request_extras!
      def enable_csp_request_extras!
        ensure_not_frozen!

        @csp_request_extras_enabled = true
      end

      # Check if the request-scoped CSP directive extras channel is enabled
      #
      # @return [Boolean] true when {#enable_csp_request_extras!} was called
      def csp_request_extras_enabled?
        @csp_request_extras_enabled
      end

      # Set the Rack env key the framework-owned lazy nonce is memoized under
      # ({Otto::Security::CSP.nonce} / {Otto::Request#csp_nonce}). Defaults to
      # `'otto.nonce'`; override it for an app with an existing convention (e.g.
      # `'onetime.nonce'`) so the accessor adopts that app's env key without a
      # rename. A blank value resets to the default.
      #
      # @param key [String] the env key
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      def csp_nonce_key=(key)
        ensure_not_frozen!

        normalized     = key.to_s.strip
        @csp_nonce_key = normalized.empty? ? 'otto.nonce' : normalized
      end

      # Check if CSP debug logging is enabled
      #
      # @return [Boolean] true if CSP debug logging is enabled
      def debug_csp?
        @debug_csp
      end

      # Configure the path browsers should POST CSP violation reports to.
      #
      # Setting this does two things:
      # 1. A `report-uri <path>` directive is appended to every emitted CSP
      #    policy — both the static policy from {#enable_csp!} and the per-request
      #    nonce policy from {#generate_nonce_csp} — so browsers know where to
      #    send violations.
      # 2. {Otto::Security::CSP::ReportMiddleware} activates for that path (it is
      #    inert until a report URI is set).
      #
      # When nil/empty (the default), NO reporting directive is emitted and the
      # policy output is byte-identical to Otto's historical output.
      #
      # For the turnkey setup that also injects the receiving middleware, prefer
      # {Otto::Security::Core#enable_csp_reporting!} on the Otto instance.
      #
      # @param uri [String, nil] path browsers POST reports to (matched against
      #   `PATH_INFO`, e.g. `/_/csp-report`), or nil to disable reporting. A
      #   value without a leading slash is coerced to an absolute path so it
      #   matches the slash-prefixed `PATH_INFO` the middleware compares against.
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      def csp_report_uri=(uri)
        ensure_not_frozen!

        @csp_report_uri = normalize_report_path(uri)
        rebuild_static_csp_with_reporting!
      end

      # Configure the absolute URL browsers should POST CSP violation reports to
      # via the modern Reporting API (Reporting-Endpoints header + `report-to`
      # directive), complementing the legacy path-based {#csp_report_uri=}.
      #
      # Setting this does two things:
      # 1. A `report-to #{CSP_REPORTING_GROUP}` directive is appended to every
      #    emitted CSP policy (static and per-request nonce alike), and a
      #    `Reporting-Endpoints` response header maps that group to this URL.
      # 2. Modern browsers (which have deprecated `report-uri`) deliver reports
      #    as `application/reports+json` to this endpoint — already parsed by
      #    {Otto::Security::CSP::Parser}.
      #
      # The value MUST be an ABSOLUTE URL (Reporting-Endpoints does not accept a
      # bare path). Point it at the same receiver as {#csp_report_uri=}: its path
      # component should equal the report URI so {Otto::Security::CSP::ReportMiddleware}
      # (which matches on PATH_INFO) intercepts modern reports too.
      #
      # When nil/empty (the default), NO `report-to` directive or
      # `Reporting-Endpoints` header is emitted and policy output is
      # byte-identical to Otto's historical output.
      #
      # @param url [String, nil] absolute URL for the Reporting API endpoint, or
      #   nil to disable modern reporting.
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      def csp_report_to_url=(url)
        ensure_not_frozen!

        @csp_report_to_url = normalize_report_uri(url)
        if @csp_report_to_url
          @security_headers['reporting-endpoints'] = reporting_endpoints_header
        else
          @security_headers.delete('reporting-endpoints')
        end
        rebuild_static_csp_with_reporting!
      end

      # Register the callback invoked once per parsed CSP violation report.
      #
      # The block receives an {Otto::Security::CSP::Report}. Your application
      # decides what to do — log, emit a metric, store, forward, or ignore. Otto
      # adds no storage or database coupling.
      #
      # Registering a second callback REPLACES the first (last registration
      # wins), matching the singular `on_csp_violation` semantics. Calling this
      # with NO block clears (unregisters) any previously-set callback.
      #
      # SECURITY NOTE: report URL fields may carry sensitive path/query data in
      # some applications. Redact them in your callback before logging if needed;
      # Otto passes them through un-redacted (see {Otto::Security::CSP::Report}).
      #
      # @yieldparam report [Otto::Security::CSP::Report] a normalized report
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      def on_csp_violation(&block)
        ensure_not_frozen!

        @csp_violation_callback = block
      end

      # Invoke the registered violation callback for a report, isolating any
      # error it raises. A misbehaving application callback must never break the
      # report receiver (which always answers 204).
      #
      # @param report [Otto::Security::CSP::Report]
      # @return [void]
      def dispatch_csp_violation(report)
        callback = @csp_violation_callback
        return if callback.nil?

        callback.call(report)
      rescue StandardError => e
        Otto.logger.error("[Otto::CSP] violation callback raised #{e.class}: #{e.message}")
      end

      # Generate a CSP policy string with the provided nonce
      #
      # Thin facade over {Otto::Security::CSP::Policy.nonce_policy}; the directive
      # sets and report-uri/report-to assembly live there now. Any configured
      # {#csp_directive_overrides} are merged into the base directive set. Output
      # is byte-identical to Otto's historical policy when no overrides or
      # reporting are configured.
      #
      # @param nonce [String] The nonce value to include in the CSP
      # @param development_mode [Boolean] Whether to use development-friendly directives
      # @param extra_directives [Hash{String=>Array<String>}, nil] request-scoped
      #   extra source tokens appended additively after the overrides merge
      #   (see {Otto::Security::CSP::Policy.append_extra_sources}, delano/otto#243).
      #   Per-request data — passed through, never stored on this (deep-frozen
      #   in production) config.
      # @yield [applied, dropped] forwarded to
      #   {Otto::Security::CSP::Policy.nonce_policy}: the extras entries that
      #   actually landed in the policy and the entries dropped because their
      #   directive was absent.
      # @return [String] Complete CSP policy string
      def generate_nonce_csp(nonce, development_mode: false, extra_directives: nil, &extras_outcome)
        Otto::Security::CSP::Policy.nonce_policy(
          nonce,
          development_mode:    development_mode,
                report_uri:    @csp_report_uri,
             report_to_url:    @csp_report_to_url,
       directive_overrides:    @csp_directive_overrides,
          extra_directives:    extra_directives,
          &extras_outcome
        )
      end

      # Enable X-Frame-Options header to prevent clickjacking
      #
      # @param option [String] Frame options: 'DENY', 'SAMEORIGIN', or 'ALLOW-FROM uri'
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      def enable_frame_protection!(option = 'SAMEORIGIN')
        ensure_not_frozen!

        @security_headers['x-frame-options'] = option
      end

      # Set custom security headers
      #
      # @param headers [Hash] Hash of header name => value pairs
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      #
      # @example
      #   config.set_custom_headers({
      #     'permissions-policy' => 'geolocation=(), microphone=()',
      #     'cross-origin-opener-policy' => 'same-origin'
      #   })
      def set_custom_headers(headers)
        ensure_not_frozen!

        @security_headers.merge!(headers)
      end

      # Override deep_freeze! to ensure rate_limiting_config has custom_rules initialized
      #
      # This pre-initializes any lazy values before freezing to prevent FrozenError
      # when accessing configuration after it's frozen.
      #
      # @return [self] The frozen configuration
      def deep_freeze!
        # Ensure custom_rules is initialized (should already be done in constructor)
        @rate_limiting_config[:custom_rules] ||= {}
        validate_trusted_proxy_config!
        validate_csrf_secret_config!
        super
      end

      def get_or_create_session_id(request)
        # Try existing sources first
        session_id = extract_existing_session_id(request)

        # Create and persist if none found
        if session_id.nil? || session_id.empty?
          session_id = SecureRandom.hex(16)
          store_session_id(request, session_id)
        end

        session_id
      end

      private

      # Guard for mutators: refuse changes once the configuration is frozen.
      # Centralizes the repeated frozen-check so every setter shares one message.
      def ensure_not_frozen!
        raise FrozenError, 'Cannot modify frozen configuration' if frozen?
      end

      # Validate a candidate trusted_proxy_depth value (type and range).
      #
      # Shared by the eager #trusted_proxy_depth= setter and the freeze-time
      # backstop so an invalid value raises a clear ArgumentError instead of a
      # downstream NoMethodError from #to_i coercion. nil disables depth mode.
      #
      # @param depth [Object] candidate value
      # @raise [ArgumentError] if depth is non-nil and not a non-negative Integer
      # @return [void]
      def validate_trusted_proxy_depth!(depth)
        return if depth.nil?

        unless depth.is_a?(Integer)
          raise ArgumentError,
                "trusted_proxy_depth must be an Integer or nil, got #{depth.class}"
        end

        raise ArgumentError, "trusted_proxy_depth must be >= 0, got #{depth}" if depth.negative?
      end

      # Canonicalize a candidate trusted_proxy_header value: match it
      # case-insensitively (ignoring surrounding whitespace) against the
      # recognized set and return the canonical spelling. Liberal in the spelling
      # it accepts (e.g. 'forwarded' => 'Forwarded') but fail-loud on a genuinely
      # unrecognized value, so a typo is caught at config time rather than
      # silently resolving the client IP from the wrong header.
      #
      # @param header [Object] candidate value
      # @raise [ArgumentError] if header is not one of TRUSTED_PROXY_HEADERS
      # @return [String] the canonical header value
      def canonicalize_trusted_proxy_header(header)
        candidate = header.to_s.strip
        canonical = TRUSTED_PROXY_HEADERS.find { |allowed| allowed.casecmp?(candidate) }
        return canonical if canonical

        raise ArgumentError,
              "trusted_proxy_header must be one of #{TRUSTED_PROXY_HEADERS.join(', ')}, got #{header.inspect}"
      end

      # Strictly validate a stored trusted_proxy_header value against the allowed
      # set. The eager #trusted_proxy_header= setter already canonicalizes, so by
      # freeze time the value is canonical; this freeze-time backstop catches a
      # value smuggled in through a direct-ivar path that bypassed the setter,
      # failing loud rather than silently mis-resolving the client IP at request
      # time.
      #
      # @param header [Object] candidate value
      # @raise [ArgumentError] if header is not one of TRUSTED_PROXY_HEADERS
      # @return [void]
      def validate_trusted_proxy_header!(header)
        return if TRUSTED_PROXY_HEADERS.include?(header)

        raise ArgumentError,
              "trusted_proxy_header must be one of #{TRUSTED_PROXY_HEADERS.join(', ')}, got #{header.inspect}"
      end

      # Validate trusted-proxy configuration coherence at freeze time.
      #
      # The eager setters (#trusted_proxy_depth=, #add_trusted_proxy) already
      # reject invalid types and the mutually-exclusive CIDR-walk vs depth
      # combination at assignment. This re-checks at finalization as a backstop
      # for a direct/ivar configuration path that bypassed the setters.
      #
      # @raise [ArgumentError] if depth is non-integer/negative, or if both
      #   trusted_proxies and a depth >= 1 are configured
      # @return [void]
      def validate_trusted_proxy_config!
        validate_trusted_proxy_header!(@trusted_proxy_header)
        validate_trusted_proxy_depth!(@trusted_proxy_depth)
        raise ArgumentError, FORWARDED_HEADER_CIDR_CONFLICT_MESSAGE if !default_trusted_proxy_header? && @trusted_proxies.any?

        if @trusted_proxy_depth
          raise ArgumentError, PROXY_MODE_CONFLICT_MESSAGE if @trusted_proxy_depth >= 1 && @trusted_proxies.any?

          # Backstop for the direct path (ip_privacy_config.geo_header=) that
          # bypasses both eager checks; the setters cover the common orders.
          raise ArgumentError, GEO_HEADER_DEPTH_CONFLICT_MESSAGE if @trusted_proxy_depth >= 1 && @ip_privacy_config&.geo_header
        end

        # Last, so a config that fails the checks above never registers as an
        # owner: late-configured proxy trust (after Otto.new) commits here at
        # the latest, so a process-wide family conflict still fails loud.
        commit_rack_forwarding_family!
      end

      # Parse a value into an IPAddr, returning nil for invalid / non-IP input.
      #
      # @param value [String] candidate IP or CIDR string
      # @return [IPAddr, nil]
      def parse_ipaddr(value)
        IPAddr.new(value)
      rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
        nil
      end

      # Build a cached matcher tuple for a proxy entry at registration time.
      #
      # String entries are parsed to an IPAddr exactly once here; the result is
      # reused for both the legacy-entry warning and per-request matching, so
      # trusted_proxy? never re-parses. Non-IP strings and Regexp/other entries
      # store a nil range and fall back to prefix/regexp matching.
      #
      # The parsed range is folded through IPAddr#native at registration, to
      # match the fold trusted_proxy? applies to the client address. Without
      # it a mapped-IPv6 proxy entry (::ffff:10.0.0.0/104) could never match,
      # because ip_in_range?'s family check would reject the folded IPv4
      # client — a proxy silently untrusted, which is what gates
      # otto.via_trusted_proxy, secure?, and geo-header trust. #native returns
      # self for entries that are not IPv4-mapped/compatible.
      #
      # @param entry [String, Regexp, Object] trusted proxy entry being added
      # @return [Array(Object, IPAddr)] [raw_entry, parsed_range_or_nil]
      def register_proxy_matcher(entry)
        return [entry, nil] unless entry.is_a?(String)

        range = parse_ipaddr(entry)&.native
        warn_legacy_proxy_entry(entry) unless range
        [entry, range]
      end

      # Warn that a string proxy entry is not a valid IP/CIDR and will use
      # legacy string-prefix matching.
      #
      # @param entry [String] trusted proxy entry
      # @return [void]
      def warn_legacy_proxy_entry(entry)
        Otto.logger.warn(
          "[Otto::Security::Config] trusted proxy #{entry.inspect} is not a " \
          'valid IP or CIDR; using legacy string-prefix matching. Prefer a ' \
          "CIDR range (e.g. '172.16.0.0/12')."
        )
      end

      # CIDR/host containment that is safe across address families.
      #
      # @param range [IPAddr] trusted proxy range or host
      # @param client [IPAddr] client address
      # @return [Boolean]
      def ip_in_range?(range, client)
        return false unless range.family == client.family

        range.include?(client)
      rescue IPAddr::InvalidAddressError
        false
      end

      def extract_existing_session_id(request)
        # Try session first
        begin
          session = request.session
          if session
            return session.id if session.respond_to?(:id) && session.id
            return session[csrf_session_key] if session[csrf_session_key]
            return session['session_id'] if session['session_id']
          end
        rescue StandardError
          # Fall through to cookies
        end

        # Try cookies
        request.cookies['_otto_session'] ||
          request.cookies['session_id'] ||
          request.cookies['_session_id']
      end

      def store_session_id(request, session_id)
        session                   = request.session
        session[csrf_session_key] = session_id if session
      rescue StandardError
        # Cookie fallback handled in inject_csrf_token
      end

      # Default security headers applied to all responses
      #
      # These headers provide basic defense against common web vulnerabilities:
      # - x-content-type-options: Prevents MIME type sniffing
      # - x-xss-protection: Enables browser XSS filtering (legacy browsers)
      # - referrer-policy: Controls referrer information leakage
      #
      # Note: Restrictive headers like HSTS, CSP, and X-Frame-Options are not
      # included by default to avoid breaking downstream applications. These
      # should be configured explicitly when appropriate.
      #
      # @return [Hash] Hash of header names and values (all lowercase for Rack 3+)
      def default_security_headers
        {
          'x-content-type-options' => 'nosniff',
          'x-xss-protection' => '1; mode=block',
          'referrer-policy' => 'strict-origin-when-cross-origin',
        }
      end

      # Perform constant-time string comparison to prevent timing attacks
      #
      # This method compares two strings in constant time regardless of where
      # they differ, preventing attackers from using timing differences to
      # deduce information about secret values.
      #
      # @param a [String, nil] First string to compare
      # @param b [String, nil] Second string to compare
      # @return [Boolean] true if strings are equal
      def secure_compare(a, b)
        return false if a.nil? || b.nil? || a.length != b.length

        result                                = 0
        a.bytes.zip(b.bytes) { |x, y| result |= x ^ y }
        result == 0
      end

      # HMAC-SHA256 signature binding a token's random component to a session id
      # and the server-side secret. Keyed HMAC (not a bare digest) is what prevents
      # token self-minting.
      def sign_csrf_token(session_id, token)
        OpenSSL::HMAC.hexdigest('SHA256', @csrf_secret, "#{session_id}:#{token}")
      end

      # Warn once per config instance when CSRF tokens are being signed with a
      # randomly-generated per-process secret. Such tokens do not survive process
      # restarts and are not shared across workers; set OTTO_CSRF_SECRET (or
      # config.csrf_secret=) for stable multi-process behavior.
      def warn_generated_csrf_secret
        return unless @csrf_secret_generated
        return if @csrf_secret_warning_emitted

        @csrf_secret_warning_emitted = true
        Otto.logger.warn(<<~MSG.gsub(/\s+/, ' ').strip)
          [Otto::Security::Config] CSRF tokens are signed with a randomly
          generated per-process secret; they will not survive restarts or be
          valid across workers. Set OTTO_CSRF_SECRET (or config.csrf_secret=)
          for stable CSRF tokens in multi-process deployments.
        MSG
      end

      # Warn once per config instance when a `script-src` override is stored for
      # the nonce CSP policy. The per-request nonce is generated at response time
      # and therefore cannot be present in a static override, so replacing (or
      # removing) `script-src` necessarily strips the nonce from the emitted
      # header — the browser then accepts any inline script the page carries the
      # nonce attribute on, voiding nonce-based protection. Overriding any other
      # directive (e.g. `worker-src`) is unaffected and stays silent.
      #
      # @param normalized [Hash] normalized (lowercased/hyphenated) overrides
      # @return [void]
      def warn_if_script_src_overridden(normalized)
        return unless normalized.key?('script-src')
        return if @csp_script_src_override_warned

        @csp_script_src_override_warned = true
        Otto.structured_log(:warn, <<~MSG.gsub(/\s+/, ' ').strip, directive: 'script-src')
          [Otto::CSP] A script-src override was configured while nonce mode is in
          use. The per-request nonce cannot be included in a static override, so
          nonce-based script protection is disabled for this policy. Remove the
          script-src override to keep nonce enforcement.
        MSG
      end

      # Freeze-time backstop: refuse to finalize a production configuration that
      # enables CSRF with a generated (non-configured) secret. Mirrors
      # #validate_trusted_proxy_config! so the failure surfaces at boot, before
      # serving traffic, for apps that deep-freeze their config.
      def validate_csrf_secret_config!
        raise ArgumentError, CSRF_SECRET_REQUIRED_MESSAGE if csrf_secret_unsafe_for_production?
      end

      # Generation-time guard for apps that never freeze their config: never
      # mint a CSRF token signed with a generated per-process secret in
      # production (fail loud instead of serving tokens that won't verify).
      def reject_generated_secret_in_production!
        raise ArgumentError, CSRF_SECRET_REQUIRED_MESSAGE if csrf_secret_unsafe_for_production?
      end

      # True when CSRF is enabled, the secret was randomly generated (not
      # configured via OTTO_CSRF_SECRET / #csrf_secret=), and we are running in
      # a production environment.
      def csrf_secret_unsafe_for_production?
        @csrf_protection && @csrf_secret_generated && production_environment?
      end

      # Whether RACK_ENV indicates a production deployment. Gated to an explicit
      # allowlist (not "anything but dev") so test/unknown environments keep the
      # zero-config generated-secret fallback.
      def production_environment?
        defined?(Otto) && Otto.respond_to?(:env?) && Otto.env?(:production, :prod)
      end

      # Normalize a configured report URI: strip surrounding whitespace and
      # treat a blank string as "not configured" (nil).
      #
      # @param uri [String, nil]
      # @return [String, nil]
      def normalize_report_uri(uri)
        return nil if uri.nil?

        stripped = uri.to_s.strip
        stripped.empty? ? nil : stripped
      end

      # Normalize a configured report PATH: the local endpoint the receiver
      # matches on `PATH_INFO`. Same strip/blank-to-nil handling as
      # {#normalize_report_uri}, but a bare relative value is coerced to an
      # absolute path — a value like `"csp-report"` would otherwise (a) never
      # equal the slash-prefixed `PATH_INFO` the middleware compares against, and
      # (b) be resolved by browsers relative to the document URL. An absolute URL
      # (contains a scheme) is left untouched.
      #
      # @param uri [String, nil]
      # @return [String, nil]
      def normalize_report_path(uri)
        normalized = normalize_report_uri(uri)
        return nil if normalized.nil?
        return normalized if normalized.start_with?('/') || normalized.include?('://')

        "/#{normalized}"
      end

      # Recompute the stored static CSP header so the report-uri / report-to
      # directives track the current settings, independent of the order in which
      # {#enable_csp!} and the report setters were called.
      #
      # The base is normally @csp_policy (set by {#enable_csp!}). When a static
      # CSP was instead injected directly through {#set_security_headers} (so
      # @csp_policy is nil), adopt that header as the base the first time a report
      # directive is configured — so reporting augments it too. Capturing it as
      # the pristine base keeps later rebuilds idempotent. A static header set
      # directly AFTER reporting is configured bypasses this and remains the
      # application's to manage.
      #
      # @return [void]
      def rebuild_static_csp_with_reporting!
        @csp_policy ||= adoptable_static_csp_base
        return if @csp_policy.nil?

        @security_headers['content-security-policy'] = build_static_csp(@csp_policy)
      end

      # The current static CSP header when it can serve as a pristine base policy
      # for reporting augmentation: present and not already carrying a report
      # directive (adopting one that does would double-append). Otherwise nil —
      # notably, the nonce path sets no static header, so nothing is adopted.
      #
      # @return [String, nil]
      def adoptable_static_csp_base
        existing = @security_headers['content-security-policy']
        return nil if existing.nil? || existing.empty?
        return nil if existing.include?('report-uri') || existing.include?('report-to')

        existing
      end

      # The `Reporting-Endpoints` response header value mapping the CSP reporting
      # group to the configured absolute endpoint URL, e.g.
      # `otto-csp="https://example.com/_/csp-report"`.
      #
      # @return [String]
      def reporting_endpoints_header
        %(#{CSP_REPORTING_GROUP}="#{@csp_report_to_url}")
      end

      # Build the stored static-CSP header value: the base policy plus the
      # optional report-uri and report-to directives. Thin facade over
      # {Otto::Security::CSP::Policy.static_policy}; byte-identical to the bare
      # policy when no reporting is configured.
      #
      # @param policy [String] the base policy passed to {#enable_csp!}
      # @return [String]
      def build_static_csp(policy)
        Otto::Security::CSP::Policy.static_policy(
          policy,
          report_uri: @csp_report_uri,
          report_to_url: @csp_report_to_url
        )
      end
    end

    # Raised when a request exceeds the configured size limit
    class RequestTooLargeError < Otto::PayloadTooLargeError; end

    # Raised when CSRF token validation fails
    class CSRFError < Otto::ForbiddenError; end

    # Raised when input validation fails (XSS, SQL injection, etc.)
    class ValidationError < Otto::BadRequestError; end
  end
end
