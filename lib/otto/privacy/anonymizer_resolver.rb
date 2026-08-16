# lib/otto/privacy/anonymizer_resolver.rb
#
# frozen_string_literal: true

class Otto
  module Privacy
    # Anonymizer (Tor / VPN / proxy / hosting) classification for IP addresses
    #
    # Answers one question — "is this address a known anonymizing egress, and
    # of what kind?" — as a single label a downstream allow/deny rule can
    # compare directly. Database-only, and the ONLY thing that ever leaves
    # this resolver is the label.
    #
    # ## Why this one reads the UNMASKED address
    #
    # Every other database lookup in Otto operates on the masked IP, because
    # country and ASN networks are >= /24 and a masked address lands in the
    # same network as the real one. Anonymizer data breaks that equivalence:
    # providers list individual egress nodes at or near /32, so a /24-masked
    # lookup answers a question about the node's *neighbours* rather than the
    # node. That produces wrong verdicts in both directions — flagging a whole
    # /24 because one host in it is an exit node, and missing the exit node
    # itself. A signal that quietly lies is worse than no signal.
    #
    # So this resolver takes the real address and returns only a label, which
    # is the same trade Otto already makes twice: {IPPrivacy.hash_ip} consumes
    # the full IP to emit an opaque digest, and +env['otto.ip_match']+ closes
    # over the full IP to emit a boolean. The invariant Otto defends is that a
    # raw address is never persisted, serialized, or handed downstream — not
    # that it is unreachable in-process. A label honours that invariant; a
    # masked lookup here would honour the letter of it while breaking the
    # feature.
    #
    # ## Reading the 'none' label
    #
    # 'none' means "the database was consulted and did not list this address".
    # Anonymizer databases are allow-list-by-omission — an address absent from
    # the file is simply not a known egress — so absence is a real answer, not
    # a miss. It is NOT a positive assertion that the address is a residential
    # user, and it is only as fresh as the database file. '**' is reserved for
    # "no database, or the lookup failed" — genuinely no answer.
    #
    # @example Configuring
    #   otto.configure_ip_privacy(
    #     anonymizer: true,
    #     anonymizer_db_path: 'data/GeoIP2-Anonymous-IP.mmdb',
    #   )
    #
    # @example Reading
    #   req.anonymizer                 # => 'tor' | 'vpn' | 'none' | '**' | nil
    #   env['otto.privacy.anonymizer']
    #
    class AnonymizerResolver
      # Returned when classification is enabled but no database answered.
      UNKNOWN = '**'

      # Returned when the database was consulted and did not list the address.
      NONE = 'none'

      # Database flag => label, in precedence order. An address can carry
      # several flags at once (a Tor exit node hosted at a cloud provider sets
      # both +is_tor_exit_node+ and +is_hosting_provider+); the FIRST match
      # wins, so the most specific and most access-relevant classification is
      # what surfaces. Ordering rationale: Tor and public proxies are
      # deliberate anonymity, commercial VPNs next, then residential proxies
      # (frequently abuse infrastructure), then hosting — which is merely "not
      # an eyeball network" and the weakest signal of the set.
      CLASSIFICATIONS = [
        %w[is_tor_exit_node tor],
        %w[is_public_proxy proxy],
        %w[is_anonymous_vpn vpn],
        %w[is_residential_proxy residential_proxy],
        %w[is_hosting_provider hosting],
        # Generic catch-all: the provider says "anonymous" without saying how.
        # Last, so it never masks a specific classification above.
        %w[is_anonymous anonymous],
      ].freeze

      # Every label this resolver can emit, for consumers building zone rules.
      LABELS = (CLASSIFICATIONS.map(&:last) + [NONE, UNKNOWN]).freeze

      class << self
        # Classify an IP address.
        #
        # @param ip [String] the UNMASKED client IP (see the class docs)
        # @param config [Otto::Privacy::Config, nil] privacy configuration
        # @return [String] one of {LABELS}
        def resolve(ip, config = nil)
          return UNKNOWN if ip.nil? || ip.empty?

          check_anonymizer_database(ip, config) || UNKNOWN
        end

        private

        # Look the address up in the configured anonymizer database.
        #
        # No masking: see the class documentation for why this resolver is the
        # one exception, and note the record is reduced to a label before it
        # returns, so the address itself goes no further.
        #
        # @return [String, nil] a label, or nil to fall through to UNKNOWN
        def check_anonymizer_database(ip, config)
          reader = config&.anonymizer_db_reader
          return nil unless reader

          classify(reader.get(ip))
        rescue StandardError => e
          warn "AnonymizerResolver database lookup error: #{e.message}" if $DEBUG
          nil
        end

        # Reduce a database record to a single label.
        #
        # A nil record means "not listed", which for an anonymizer database is
        # the meaningful answer NONE rather than a miss — these files record
        # only flagged addresses. A non-Hash record is a malformed answer and
        # falls through to UNKNOWN.
        #
        # @return [String, nil]
        def classify(record)
          return NONE if record.nil?
          return nil unless record.is_a?(Hash)

          match = CLASSIFICATIONS.find { |flag, _label| flagged?(record[flag]) }
          match ? match.last : NONE
        end

        # MaxMind omits these keys entirely when false, so absent and false are
        # the same answer. Accept the string forms too, since MMDB builds from
        # other vendors sometimes encode the flags as text.
        def flagged?(value)
          value == true || value.to_s == 'true' || value.to_s == '1'
        end
      end
    end
  end
end
