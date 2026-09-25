# lib/otto/security/trusted_proxy_config.rb
#
# frozen_string_literal: true

require 'ipaddr'
require_relative '../core/freezable'

class Otto
  module Security
    # Trusted-proxy resolution settings for one Otto application.
    #
    # An application answers "which peer may speak for the client?" in at most
    # one of three ways (#mode):
    #
    # - :filter — enumerated proxy entries (IP, CIDR, Regexp, or a legacy
    #   string prefix); the client IP is found by walking the forwarded chain
    #   past trusted hops.
    # - :depth — trust the last N hops, for proxy tiers whose addresses cannot
    #   be enumerated (Fly, cloud load balancers, dynamic reverse proxies).
    # - :none — the explicit operator assertion that no proxy is trusted.
    #
    # #header picks the forwarded header depth mode counts hops from.
    #
    # This object owns the rules that keep those settings coherent. #mode is
    # derived from the stored settings rather than stored beside them, and
    # every mutator checks the state it would produce with #ensure_compatible!,
    # the same check #validate! runs at freeze, so each rule is written once.
    #
    # Rules that involve other objects stay with Otto::Security::Config: the
    # ip_privacy geo_header vs depth conflict, and pinning Rack's
    # process-global forwarding family. Config keeps this object private and
    # routes every change through its own setters (add_trusted_proxy,
    # trusted_proxy_depth=, trusted_proxy_header=, trust_no_proxies!), which
    # add those checks; #check_depth! and #check_header! let Config run them
    # before anything is stored.
    class TrustedProxyConfig
      include Otto::Core::Freezable

      # Error raised when the two mutually-exclusive trusted-proxy resolution
      # modes are configured together: CIDR-walk (enumerated trusted_proxies)
      # and count-based depth (trusted_proxy_depth >= 1).
      PROXY_MODE_CONFLICT_MESSAGE = <<~MSG.gsub(/\s+/, ' ').strip.freeze
        Cannot configure both trusted_proxies (CIDR filter mode) and
        trusted_proxy_depth >= 1 (count mode). Enumerate proxy CIDRs OR set a
        hop count, not both.
      MSG

      # Error raised when the explicit "trust no proxy" assertion
      # (trust_no_proxies!, `trusted_proxies: :none`) is combined with an
      # actual trust grant (enumerated CIDRs or a depth >= 1). The two say
      # opposite things about the same peer, so the combination is refused at
      # configuration time rather than silently resolved in one direction.
      TRUST_NO_PROXIES_CONFLICT_MESSAGE = <<~MSG.gsub(/\s+/, ' ').strip.freeze
        Cannot combine trusted_proxies: :none (trust no proxy) with
        trusted_proxies CIDRs or trusted_proxy_depth >= 1. Assert :none OR
        grant trust, not both.
      MSG

      # Error raised when the trust-nobody sentinel arrives as a proxy ENTRY
      # (`trusted_proxies: ['none']`, as a YAML/JSON list naturally yields, or
      # `add_trusted_proxy('none')`) instead of as the whole option. Inside a
      # list it would otherwise register a legacy string-prefix matcher that
      # matches nothing: peers would be untrusted, but trust_no_proxies? would
      # stay false and the config would stake a forwarding-family claim, so the
      # explicit assertion would be silently replaced by a lookalike.
      TRUST_NO_PROXIES_ENTRY_MESSAGE = <<~MSG.gsub(/\s+/, ' ').strip.freeze
        trusted_proxies entry :none is the trust-nobody assertion, not a proxy
        address. Pass trusted_proxies: :none as the whole option (not inside a
        list) or call trust_no_proxies! instead.
      MSG

      # Error raised when a non-default header is combined with CIDR filter
      # mode. Otto's CIDR-walk resolves the client IP from the X-Forwarded-For
      # family only (X-Forwarded-For, then X-Real-IP, then X-Client-IP —
      # Otto::Utils::FORWARDED_FOR_HEADERS), never RFC 7239 Forwarded, while
      # trusted_proxy_header also pins Rack's forwarding family; honoring
      # 'Forwarded' or 'Both' there would make Rack read a header Otto ignores,
      # recreating the disagreement the pin exists to close.
      FORWARDED_HEADER_CIDR_CONFLICT_MESSAGE = <<~MSG.gsub(/\s+/, ' ').strip.freeze
        Cannot configure trusted_proxy_header 'Forwarded' or 'Both' together
        with trusted_proxies (CIDR filter mode): CIDR-walk resolves client IPs
        from the X-Forwarded-For family only (X-Forwarded-For, X-Real-IP,
        X-Client-IP), never RFC 7239 Forwarded. Use trusted_proxy_depth (count
        mode) to read the RFC 7239 Forwarded header.
      MSG

      # Sentinel accepted wherever a trusted_proxies list is accepted, meaning
      # "the operator asserts that NO proxy is trusted". See #trust_none!.
      TRUST_NO_PROXIES = :none

      # Forwarded-header sources depth mode can count hops from:
      # X-Forwarded-For (default), the RFC 7239 Forwarded header, or Both
      # (Forwarded when present, else X-Forwarded-For). Mirrors OneTimeSecret's
      # site.network.trusted_proxy.header. Only consulted in depth mode;
      # CIDR-walk is unaffected.
      HEADERS = %w[X-Forwarded-For Forwarded Both].freeze
      DEFAULT_HEADER = 'X-Forwarded-For'

      # Whether a trusted_proxies option value is the trust-nobody sentinel.
      # Accepts the symbol and the String spelling 'none' (case-insensitive),
      # which is what YAML/ENV-driven configuration naturally produces; without
      # this, 'none' would fall through to #add and install a legacy
      # string-prefix matcher, silently inverting the assertion.
      #
      # @param value [Object] raw trusted_proxies option
      # @return [Boolean]
      def self.trust_no_proxies_option?(value)
        (value.is_a?(Symbol) || value.is_a?(String)) && value.to_s.casecmp?('none')
      end

      # Proxy entries in registration order (filter mode).
      # @return [Array<String, Regexp>]
      attr_reader :proxies

      # Count-based depth; nil or 0 disables depth mode.
      # @return [Integer, nil]
      attr_reader :depth

      # Canonical forwarded header depth mode counts hops from.
      # @return [String] one of HEADERS
      attr_reader :header

      def initialize
        @proxies    = []
        @matchers   = []
        @trust_none = false
        @depth      = nil
        @header     = DEFAULT_HEADER
      end

      # The active resolution mode, or nil when proxy trust is unconfigured.
      #
      # @return [Symbol, nil] :filter, :depth, :none, or nil
      def mode
        return :filter if filter?
        return :depth if depth?

        :none if trust_none?
      end

      # Whether any mode is configured. When false, Otto leaves
      # env['otto.via_trusted_proxy'] absent (the tri-state contract).
      #
      # @return [Boolean]
      def configured?
        !mode.nil?
      end

      # Whether proxy entries are registered (CIDR filter mode).
      #
      # @return [Boolean]
      def filter?
        @matchers.any?
      end

      # Whether count-based depth mode is active. Integer-strict, so a value
      # that never passed #depth= cannot enable it.
      #
      # @return [Boolean] true when depth is an Integer >= 1
      def depth?
        @depth.is_a?(Integer) && @depth >= 1
      end

      # Whether the operator asserted that no proxy is trusted.
      #
      # @return [Boolean]
      def trust_none?
        @trust_none
      end

      # Whether request handling reads a forwarded chain, and so depends on
      # Rack's process-global forwarding family. True in filter and depth mode;
      # false under trust-nobody (reads nothing) and when unconfigured.
      #
      # @return [Boolean]
      def forwarding_family_dependent?
        filter? || depth?
      end

      # Whether #header is the X-Forwarded-For default.
      #
      # @return [Boolean]
      def default_header?
        @header == DEFAULT_HEADER
      end

      # Register one entry or a list of entries (filter mode). The whole list
      # is validated before anything is registered, so a rejected list leaves
      # this object untouched.
      #
      # @param proxy [String, Regexp, Array<String, Regexp>] entry or entries
      # @raise [ArgumentError] on a mode conflict, a trust-nobody sentinel
      #   inside the list, or an unsupported type
      # @raise [FrozenError] if frozen
      # @return [void]
      def add(proxy)
        ensure_not_frozen!
        # Adding claims filter mode even when the list is empty, so the
        # conflict surfaces at the call that introduced it.
        ensure_compatible!(filter: true)
        Array(proxy).each do |entry|
          raise ArgumentError, TRUST_NO_PROXIES_ENTRY_MESSAGE if self.class.trust_no_proxies_option?(entry)
        end

        case proxy
        when String, Regexp
          @proxies << proxy
          @matchers << build_matcher(proxy)
        when Array
          proxy.each { |entry| @matchers << build_matcher(entry) }
          @proxies.concat(proxy)
        else
          raise ArgumentError, 'Proxy must be a String, Regexp, or Array'
        end
      end

      # Assert that no proxy is trusted.
      #
      # @raise [ArgumentError] if entries or a depth >= 1 are configured
      # @raise [FrozenError] if frozen
      # @return [void]
      def trust_none!
        ensure_not_frozen!
        ensure_compatible!(trust_none: true)
        @trust_none = true
      end

      # Raise unless depth could be assigned: a non-negative Integer or nil,
      # compatible with the current mode. Stores nothing.
      #
      # @param depth [Object] candidate value
      # @raise [ArgumentError] if invalid or conflicting
      # @return [Integer, nil] depth
      def check_depth!(depth)
        validate_depth_value!(depth)
        ensure_compatible!(depth: depth.to_i >= 1)
        depth
      end

      # @param depth [Integer, nil] number of trusted hops (nil/0 disables depth mode)
      # @raise [ArgumentError] if invalid or conflicting (see #check_depth!)
      # @raise [FrozenError] if frozen
      def depth=(depth)
        ensure_not_frozen!
        @depth = check_depth!(depth)
      end

      # Raise unless header could be assigned, and return its canonical
      # spelling. Matching is case-insensitive and ignores surrounding
      # whitespace; an unrecognized value fails loud instead of silently
      # resolving from the wrong header. Stores nothing.
      #
      # @param header [Object] candidate value
      # @raise [ArgumentError] if unrecognized or conflicting with filter mode
      # @return [String] canonical header (one of HEADERS)
      def check_header!(header)
        candidate = header.to_s.strip
        canonical = HEADERS.find { |allowed| allowed.casecmp?(candidate) }
        raise ArgumentError, invalid_header_message(header) unless canonical

        ensure_compatible!(header: canonical)
        canonical
      end

      # @param header [String] one of HEADERS (case-insensitive)
      # @raise [ArgumentError] if invalid or conflicting (see #check_header!)
      # @raise [FrozenError] if frozen
      def header=(header)
        ensure_not_frozen!
        @header = check_header!(header)
      end

      # Whether ip matches a registered entry.
      #
      # String entries that parse as an IP or CIDR range are matched with
      # proper IPAddr containment (IPv4 and IPv6). Entries that are not valid
      # IPs (e.g. a bare prefix like '172.16.') fall back to the legacy
      # exact/prefix string match for backward compatibility. Regexp entries
      # are matched against the raw IP string. Entries are parsed once at
      # registration, never per request.
      #
      # @param ip [String] IP address to check
      # @return [Boolean]
      def trusted?(ip)
        return false if @matchers.empty? || ip.nil? || ip.empty?

        # Fold IPv4-mapped IPv6 (::ffff:a.b.c.d) to plain IPv4 so a dual-stack
        # peer presented in mapped form still matches an IPv4 proxy entry.
        client = parse_ipaddr(ip)&.native

        @matchers.any? do |entry, range|
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

      # Re-check every rule against the stored state. The mutators already
      # enforce them; this is the freeze-time backstop for state that bypassed
      # them (a direct instance-variable write).
      #
      # @raise [ArgumentError] if any rule is violated
      # @return [void]
      def validate!
        raise ArgumentError, invalid_header_message(@header) unless HEADERS.include?(@header)

        validate_depth_value!(@depth)
        ensure_compatible!
      end

      private

      def ensure_not_frozen!
        raise FrozenError, 'Cannot modify frozen configuration' if frozen?
      end

      # The mutual-exclusion rules, in one place. Each flag says whether that
      # mode would be active; a mutator overrides the one it is about to
      # change and the rest default to the stored state.
      def ensure_compatible!(filter: filter?, depth: depth?, trust_none: trust_none?, header: @header)
        raise ArgumentError, PROXY_MODE_CONFLICT_MESSAGE if filter && depth
        raise ArgumentError, TRUST_NO_PROXIES_CONFLICT_MESSAGE if trust_none && (filter || depth)
        raise ArgumentError, FORWARDED_HEADER_CIDR_CONFLICT_MESSAGE if filter && header != DEFAULT_HEADER
      end

      # Type and range only, so an invalid value raises a clear ArgumentError
      # instead of a downstream NoMethodError from #to_i coercion.
      def validate_depth_value!(depth)
        return if depth.nil?

        unless depth.is_a?(Integer)
          raise ArgumentError,
                "trusted_proxy_depth must be an Integer or nil, got #{depth.class}"
        end

        raise ArgumentError, "trusted_proxy_depth must be >= 0, got #{depth}" if depth.negative?
      end

      def invalid_header_message(header)
        "trusted_proxy_header must be one of #{HEADERS.join(', ')}, got #{header.inspect}"
      end

      # Parse a value into an IPAddr, returning nil for invalid / non-IP input.
      def parse_ipaddr(value)
        IPAddr.new(value)
      rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
        nil
      end

      # Build a cached [raw_entry, parsed_range_or_nil] tuple at registration.
      #
      # The parsed range is folded through IPAddr#native, to match the fold
      # #trusted? applies to the client address. Without it a mapped-IPv6
      # proxy entry (::ffff:10.0.0.0/104) could never match, because
      # #ip_in_range?'s family check would reject the folded IPv4 client — a
      # proxy silently untrusted, which is what gates otto.via_trusted_proxy,
      # secure?, and geo-header trust. #native returns self for entries that
      # are not IPv4-mapped/compatible.
      def build_matcher(entry)
        return [entry, nil] unless entry.is_a?(String)

        range = parse_ipaddr(entry)&.native
        warn_legacy_proxy_entry(entry) unless range
        [entry, range]
      end

      def warn_legacy_proxy_entry(entry)
        Otto.logger.warn(
          "[Otto::Security::Config] trusted proxy #{entry.inspect} is not a " \
          'valid IP or CIDR; using legacy string-prefix matching. Prefer a ' \
          "CIDR range (e.g. '172.16.0.0/12')."
        )
      end

      # CIDR/host containment that is safe across address families.
      def ip_in_range?(range, client)
        return false unless range.family == client.family

        range.include?(client)
      rescue IPAddr::InvalidAddressError
        false
      end
    end
  end
end
