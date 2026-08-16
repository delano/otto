# lib/otto/privacy.rb
#
# frozen_string_literal: true

require_relative 'privacy/core'
require_relative 'privacy/config'
require_relative 'privacy/ip_privacy'
require_relative 'privacy/user_agent_privacy'
require_relative 'privacy/geo_resolver'
require_relative 'privacy/asn_resolver'
require_relative 'privacy/anonymizer_resolver'
require_relative 'privacy/redacted_fingerprint'

# Otto::Privacy module provides IP address anonymization and privacy features
#
# By default, Otto anonymizes IP addresses to enhance user privacy and
# comply with data protection regulations like GDPR. Original IP addresses
# are never stored unless privacy is explicitly disabled.
#
# Features:
# - Configurable IP masking (1 or 2 octets for IPv4, 80 or 96 bits for IPv6)
# - Daily-rotating IP hashing for session correlation without tracking
# - Geo-location resolution (country-level only): a configurable trusted header,
#   built-in CDN provider headers, an optional local MaxMind-format (.mmdb)
#   database looked up on the masked IP, or a custom resolver
# - ASN resolution (opt-in, default off): the network operator an address
#   belongs to, from a local .mmdb looked up on the masked IP. Database-only —
#   no CDN publishes a client-ASN header worth trusting
# - Anonymizer classification (opt-in, default off): whether an address is a
#   known Tor / VPN / proxy / hosting egress, from a local .mmdb. The only
#   lookup that reads the unmasked address, because anonymizer data lists
#   individual nodes at /32 — it returns a label, never the address
# - User agent anonymization (removes version numbers)
#
# Privacy is ENABLED BY DEFAULT. To disable:
#   otto.disable_ip_privacy!
#
# To configure privacy settings:
#   otto.configure_ip_privacy(octet_precision: 2, geo: true)
#
class Otto
  module Privacy
  end
end
