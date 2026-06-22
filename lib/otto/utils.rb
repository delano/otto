# lib/otto/utils.rb
#
# frozen_string_literal: true

require 'ipaddr'

class Otto
  # Utility methods for common operations and helpers
  module Utils
    extend self

    # Forwarded-for style headers consulted (in order) when resolving the real
    # client IP from behind a trusted proxy. Shared by IPPrivacyMiddleware and
    # Otto::Request so the two resolvers cannot drift.
    FORWARDED_FOR_HEADERS = %w[
      HTTP_X_FORWARDED_FOR
      HTTP_X_REAL_IP
      HTTP_X_CLIENT_IP
    ].freeze

    # Special-use IPv4/IPv6 ranges that IPAddr's #private?/#loopback?/#link_local?
    # predicates do not cover but that should still be treated as non-public
    # (e.g. when picking the real client out of a forwarded chain).
    SPECIAL_USE_RANGES = [
      IPAddr.new('0.0.0.0/8'),   # "this" network / unspecified (IPv4)
      IPAddr.new('224.0.0.0/4'), # IPv4 multicast
      IPAddr.new('::/128'),      # IPv6 unspecified
      IPAddr.new('ff00::/8'),    # IPv6 multicast
    ].freeze

    # @return [Time] Current time in UTC
    def now
      Time.now.utc
    end

    # Returns the current time in microseconds.
    # This is used to measure the duration of Database commands.
    #
    # Alias: now_in_microseconds
    #
    # @return [Integer] The current time in microseconds.
    def now_in_μs
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
    end
    alias now_in_microseconds now_in_μs

    # Determine if a value represents a "yes" or true value
    #
    # @param value [Object] The value to evaluate
    # @return [Boolean] True if the value represents "yes", false otherwise
    #
    # Examples:
    # yes?('true')  # => true
    # yes?('yes')   # => true
    # yes?('1')     # => true
    def yes?(value)
      !value.to_s.empty? && %w[true yes 1].include?(value.to_s.downcase)
    end

    # Validate and normalize an IP address (IPv4 and IPv6).
    #
    # Strips an optional port (IPv6-safe), validates with IPAddr, and returns
    # the cleaned address string, or nil if the input is blank or malformed.
    #
    # @param ip [String, nil] candidate address, optionally with a port
    # @return [String, nil] cleaned IP string, or nil if invalid
    def normalize_ip(ip)
      return nil if ip.nil? || ip.empty?

      candidate = strip_ip_port(ip.strip)
      return nil if candidate.nil? || candidate.empty?

      # IPAddr validates both IPv4 and IPv6; raises for malformed input
      IPAddr.new(candidate)
      candidate
    rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
      nil
    end

    # Strip an optional port without corrupting IPv6 addresses.
    #
    # Handles bracketed IPv6 with a port (`[2001:db8::1]:443`) and IPv4
    # host:port (`203.0.113.5:443`). A bare IPv6 address (multiple colons,
    # no brackets) is returned unchanged.
    #
    # @param ip [String] candidate address, possibly including a port
    # @return [String] address with any port removed
    def strip_ip_port(ip)
      if ip.start_with?('[')
        inner = ip[/\A\[([^\]]+)\]/, 1]
        return inner if inner
      end

      return ip.split(':', 2).first if ip.count(':') == 1

      ip
    end

    # Resolve the real client IP from a Rack env, honoring forwarded headers
    # only when the connecting peer (REMOTE_ADDR) is a trusted proxy.
    #
    # This is the single canonical resolver shared by IPPrivacyMiddleware
    # ("resolve once") and Otto::Request#client_ipaddress (its no-middleware
    # fallback), so both paths agree on which headers to trust and how to walk
    # a proxy chain. It walks the forwarded chain left-to-right and returns the
    # first address that is not itself a trusted proxy; if the peer is not a
    # trusted proxy (or there is no config) it returns REMOTE_ADDR unchanged.
    #
    # @param env [Hash] Rack environment
    # @param security_config [Otto::Security::Config, nil] config exposing #trusted_proxy?
    # @return [String, nil] resolved client IP (the raw REMOTE_ADDR when no proxy applies)
    def resolve_client_ip(env, security_config)
      remote_addr = env['REMOTE_ADDR']

      # Count-based ("trust the last N hops") mode for non-enumerable proxy
      # tiers (Fly, cloud load balancers, dynamic reverse proxies) where the
      # CIDR-walk below has no enumerable proxy IPs to match. Mirrors Express
      # `trust proxy = N`. Takes precedence over CIDR-walk; the two modes are
      # mutually exclusive (enforced at config freeze).
      return resolve_client_ip_by_depth(env, security_config) if security_config&.trusted_proxy_depth_mode?

      # No config, or the peer is a direct (untrusted) connection: REMOTE_ADDR
      # is the client. Don't honor forwarded headers from untrusted sources.
      return remote_addr unless security_config&.trusted_proxy?(remote_addr)

      forwarded_ips = FORWARDED_FOR_HEADERS
                      .filter_map { |header| env[header] }
                      .flat_map { |value| value.split(/,\s*/) }

      forwarded_ips.each do |candidate|
        clean_ip = normalize_ip(candidate.strip)
        next unless clean_ip

        # First address in the chain that isn't a known proxy is the client.
        return clean_ip unless security_config.trusted_proxy?(clean_ip)
      end

      # Whole chain was trusted proxies (or empty): fall back to the peer.
      remote_addr
    end

    # Resolve the client IP by trusting a fixed number of proxy hops, counted
    # from the right of the forwarded chain (Express `trust proxy = N`). Used
    # when the proxy tier's addresses cannot be enumerated as CIDRs.
    #
    # The chain is the configured forwarded header (leftmost = client ..
    # rightmost = nearest proxy) plus REMOTE_ADDR (the direct peer). With depth
    # N the client is chain[-(N+1)] — exactly N trusted hops from the right,
    # equivalent to Express's addrs[N]. This is robust to forwarded-header
    # padding: a forged leftmost entry is never reached.
    #
    # SECURITY: depth trust ASSUMES ORIGIN LOCKDOWN — the app must be
    # unreachable except through the proxy tier. Without it, a direct client
    # could pad the forwarded header to land a forged value at the target index.
    # This is the inherent trade vs CIDR-walk (a fixed hop count instead of
    # enumerable proxy addresses).
    #
    # The forwarded chain is selected by security_config.trusted_proxy_header:
    # 'X-Forwarded-For' (default), 'Forwarded' (RFC 7239), or 'Both' (RFC 7239
    # when it carries a `for=`, otherwise X-Forwarded-For — mirrors
    # OneTimeSecret's site.network.trusted_proxy.header). X-Real-IP / X-Client-IP
    # are single-value and cannot express a hop chain, so they are never
    # consulted in depth mode. Positions are counted raw (never dropped), so junk
    # padding cannot shift the index; only the selected entry is validated. If
    # the chain is shorter than N+1 (a request that may have bypassed the proxy
    # tier) or the selected entry is invalid, REMOTE_ADDR is returned rather than
    # a spoofable forwarded value.
    #
    # @param env [Hash] Rack environment
    # @param security_config [Otto::Security::Config] config exposing #trusted_proxy_depth and #trusted_proxy_header
    # @return [String, nil] resolved client IP (REMOTE_ADDR on short chain / invalid target)
    def resolve_client_ip_by_depth(env, security_config)
      remote_addr = env['REMOTE_ADDR']
      depth       = security_config.trusted_proxy_depth.to_i

      # Build the positional hop chain from the configured header, keeping every
      # position (junk/empty entries included) so the client can be located by
      # counting from the right; dropping entries would let padding shift the
      # index. REMOTE_ADDR (the direct peer) is the rightmost hop.
      forwarded = forwarded_chain_for_depth(env, security_config.trusted_proxy_header)
      chain     = forwarded + [remote_addr]

      index = chain.length - (depth + 1)
      return remote_addr if index.negative? # chain shorter than depth + 1

      normalize_ip(chain[index].to_s.strip) || remote_addr
    end

    # Positional forwarded-hop chain for depth resolution, selected by header
    # mode. Each element is one hop (preserving count); values are raw — only the
    # finally-selected entry is normalized. Mirrors OneTimeSecret's
    # site.network.trusted_proxy.header semantics.
    #
    # @param env [Hash] Rack environment
    # @param header_mode [String] 'X-Forwarded-For', 'Forwarded', or 'Both'
    # @return [Array<String>] one entry per hop (may include blank/invalid entries)
    def forwarded_chain_for_depth(env, header_mode)
      case header_mode
      when 'Forwarded'
        rfc7239_for_chain(env['HTTP_FORWARDED'])
      when 'Both'
        # RFC 7239 wins when it carries at least one `for=`; otherwise fall back
        # to X-Forwarded-For. The chains are NOT merged (matches OTS's
        # `extract_rfc7239_forwarded(env) || extract_x_forwarded_for(env)`).
        forwarded = rfc7239_for_chain(env['HTTP_FORWARDED'])
        forwarded.any? { |entry| !entry.empty? } ? forwarded : xff_chain(env['HTTP_X_FORWARDED_FOR'])
      else
        xff_chain(env['HTTP_X_FORWARDED_FOR'])
      end
    end

    # Split X-Forwarded-For into raw positional entries. `-1` keeps trailing
    # empty fields so a malformed/empty hop still counts as a position.
    #
    # @param value [String, nil] raw X-Forwarded-For header value
    # @return [Array<String>]
    def xff_chain(value)
      value.to_s.split(',', -1)
    end

    # Extract the per-hop `for=` chain from an RFC 7239 Forwarded header,
    # preserving one position per forwarded-element. Elements without a `for=`
    # parameter yield a blank placeholder so they still occupy a hop position
    # (raw position counting). The extracted token is only unquoted here; port
    # and IPv6 brackets are left for normalize_ip when the entry is selected.
    # Obfuscated (`for=_hidden`) and `for=unknown` identifiers are preserved as
    # positions but normalize to nil (→ REMOTE_ADDR fallback if selected).
    # Commas separate forwarded-elements (and join multiple Forwarded headers).
    #
    # @param value [String, nil] raw Forwarded header value
    # @return [Array<String>] one `for=` token per forwarded-element
    def rfc7239_for_chain(value)
      value.to_s.split(',', -1).map { |element| rfc7239_for_value(element) }
    end

    # Pull the `for=` token out of a single RFC 7239 forwarded-element. The value
    # is either a quoted-string (which may itself legally contain ';') or an
    # unquoted token ending at the next ';'. The quoted form is matched first so
    # a ';' inside DQUOTEs is NOT treated as a parameter separator — otherwise a
    # quoted value like for="1.2.3.4;junk" would be truncated to a valid-looking
    # IP instead of being rejected. The surrounding DQUOTEs are stripped; the
    # raw value (port / IPv6 brackets intact) is left for normalize_ip when the
    # entry is selected. Returns '' when the element carries no `for=` parameter,
    # preserving the hop position. The `for=` pair may be the element's first
    # pair or follow a ';'; leading whitespace (e.g. after a comma split) is
    # tolerated.
    #
    # @param element [String] one forwarded-element (e.g. 'for=1.2.3.4;proto=https')
    # @return [String]
    def rfc7239_for_value(element)
      match = element.match(/(?:\A|;)\s*for=(?:"([^"]*)"|([^;]*))/i)
      return '' unless match

      (match[1] || match[2]).to_s.strip
    end

    # Whether an address is non-public: RFC1918 private, loopback, link-local,
    # multicast, or unspecified — for both IPv4 and IPv6.
    #
    # Uses IPAddr's family-aware predicates (which also fold IPv4-mapped IPv6
    # via #native) plus an explicit set of special-use ranges that the
    # predicates don't cover (IPv4 0.0.0.0/8 and 224.0.0.0/4, IPv6 ::/128 and
    # ff00::/8). Returns false for malformed input rather than raising.
    #
    # @param ip [String, IPAddr, nil] address to classify
    # @return [Boolean]
    def private_ip?(ip)
      return false if ip.nil?
      return false if ip.respond_to?(:empty?) && ip.empty?

      addr = ip.is_a?(IPAddr) ? ip : IPAddr.new(strip_ip_port(ip.to_s.strip))
      addr = addr.native # fold IPv4-mapped IPv6 (::ffff:a.b.c.d) to IPv4

      return true if addr.private? || addr.loopback? || addr.link_local?

      SPECIAL_USE_RANGES.any? { |range| range.family == addr.family && range.include?(addr) }
    rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
      false
    end
  end
end
