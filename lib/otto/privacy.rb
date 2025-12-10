# lib/otto/privacy.rb
#
# frozen_string_literal: true

require_relative 'privacy/core'
require_relative 'privacy/config'
require_relative 'privacy/ip_privacy'
require_relative 'privacy/geo_resolver'
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
# - Geo-location resolution (country-level only, via CloudFlare headers)
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
