# lib/otto/privacy/asn_resolver.rb
#
# frozen_string_literal: true

class Otto
  module Privacy
    # Autonomous System Number (ASN) resolution for IP addresses
    #
    # Provides the network operator an address belongs to, as a privacy-safe
    # label a downstream allow/deny rule can compare directly. Resolution is
    # database-only and operates on Otto's already-MASKED IP, exactly as
    # {GeoResolver}'s database fallback does — the unmasked address never
    # reaches this resolver.
    #
    # Resolution order (first hit wins), when a privacy Config is supplied:
    # 1. Local MMDB lookup, masked before lookup (Config#asn_db_reader)
    # 2. '**' (unknown)
    #
    # Resolution is honest: when no database resolves an ASN, the answer is
    # '**' — never a guess. A caller can therefore distinguish three states:
    # nil (ASN resolution is switched off), '**' (on, but no answer), and a
    # real label.
    #
    # ## Why database-only
    #
    # Unlike country, no CDN publishes a client-ASN header with meaningful
    # deployment, so there is no header tier to trust. Staying database-only
    # also keeps ASN clear of the geo_header/trusted_proxy_depth boot conflict
    # ({Otto::Security::Config::GEO_HEADER_DEPTH_CONFLICT_MESSAGE}): there is
    # no header to be silently ignored under count-based proxy trust.
    #
    # ## Masking and accuracy
    #
    # IPv4 BGP routes are not announced longer than /24, so a /24-masked
    # address lands in the same announced prefix — and therefore the same
    # ASN — as the real one. That equivalence is what makes a masked lookup
    # honest here, and it is weaker than it looks for IPv6: at
    # +octet_precision: 1+ Otto zeroes the last 80 bits (a /48), which is
    # coarser than many IPv6 announcements. Treat IPv6 ASN as best-effort.
    #
    # @example Configuring
    #   otto.configure_ip_privacy(asn: true, asn_db_path: 'data/GeoLite2-ASN.mmdb')
    #
    # @example Reading
    #   req.asn                       # => 'AS15169' | '**' | nil
    #   env['otto.privacy.asn']
    #
    class AsnResolver
      # Returned when ASN resolution is enabled but nothing resolved. Shared
      # spelling with {GeoResolver::UNKNOWN} so consumers can treat every
      # privacy label the same way.
      UNKNOWN = '**'

      # Reserved ASNs that carry no operator meaning: 0 is "reserved by the
      # IANA" (RFC 7607) and 23456 is the AS_TRANS placeholder a 2-byte-only
      # speaker substitutes for a 4-byte ASN (RFC 6793). A database that
      # returns either has told us nothing, so both resolve to UNKNOWN rather
      # than being dressed up as an answer.
      RESERVED = [0, 23_456].freeze

      # Highest assignable ASN; 4_294_967_295 is reserved (RFC 7300).
      MAX_ASN = 4_294_967_294

      class << self
        # Resolve an ASN label for an IP address.
        #
        # @param ip [String] the ALREADY-MASKED client IP
        # @param config [Otto::Privacy::Config, nil] privacy configuration
        # @return [String] 'AS<number>' or {UNKNOWN}
        def resolve(ip, config = nil)
          return UNKNOWN if ip.nil? || ip.empty?

          check_asn_database(ip, config) || UNKNOWN
        end

        private

        # Look the masked IP up in the configured ASN database.
        #
        # The reader is any object responding to +#get(ip)+. A database read
        # must never crash a request, so every StandardError falls through to
        # "unknown" — the same posture {GeoResolver.check_geo_database} takes.
        #
        # @return [String, nil] 'AS<number>', or nil to fall through
        def check_asn_database(ip, config)
          reader = config&.asn_db_reader
          return nil unless reader

          # Re-mask defensively: masking is idempotent, so this costs nothing
          # for an already-masked address and closes the hole if a caller ever
          # hands us a raw one directly.
          lookup_ip = IPPrivacy.mask_ip(ip, config.octet_precision) || ip
          format_asn(extract_db_asn(reader.get(lookup_ip)))
        rescue StandardError => e
          warn "AsnResolver database lookup error: #{e.message}" if $DEBUG
          nil
        end

        # Pull the AS number out of a database record.
        #
        # MaxMind's GeoLite2-ASN stores a flat +autonomous_system_number+ as a
        # uint32. Some combined builds nest it under an 'asn' map, and a few
        # emit the bare key 'asn'. Accept all three; anything else is not an
        # answer.
        #
        # NOTE: the value is an Integer, not a String — the opposite of
        # {GeoResolver.extract_db_country}'s terminal guard. Copying that
        # method's String check here would discard every real hit.
        #
        # @return [Integer, nil]
        def extract_db_asn(result)
          return nil unless result.is_a?(Hash)

          asn = result['asn']
          number =
            if asn.is_a?(Hash)
              asn['autonomous_system_number'] || asn['number']
            else
              result['autonomous_system_number'] || asn
            end
          valid_asn?(number) ? number : nil
        end

        # @return [Boolean] whether the number is an assignable, meaningful ASN
        def valid_asn?(number)
          number.is_a?(Integer) &&
            number.positive? &&
            number <= MAX_ASN &&
            !RESERVED.include?(number)
        end

        # Render as the conventional 'AS<number>' text form.
        #
        # A String — never the bare Integer — because the whole resolution
        # chain, and Otto::Request's env fallbacks, treat a falsey value as
        # "keep looking". A label is also what a downstream zone rule compares
        # against, and it leaves room for the '**' sentinel that an Integer
        # representation has no way to express.
        #
        # @return [String, nil]
        def format_asn(number)
          return nil if number.nil?

          "AS#{number}"
        end
      end
    end
  end
end
