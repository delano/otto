# lib/otto/privacy/user_agent_privacy.rb
#
# frozen_string_literal: true

class Otto
  module Privacy
    # User-Agent anonymization utilities.
    #
    # Reduces a User-Agent string to a lower-entropy form by stripping build
    # identifiers and version numbers and truncating, so it can be logged or
    # stored for analytics without a high-entropy fingerprint while preserving
    # browser/OS family information. This is the User-Agent analogue of
    # {IPPrivacy} for IP addresses, exposed as a public surface so downstream
    # consumers can reduce a UA outside of the full RedactedFingerprint /
    # middleware flow without re-implementing (and drifting from) these regexes.
    #
    # @example
    #   UserAgentPrivacy.anonymize(
    #     'Mozilla/5.0 (Windows NT 10.0) Chrome/119.0.0.0 Safari/537.36'
    #   )
    #   # => 'Mozilla/*.* (Windows NT *.*) Chrome/*.*.*.* Safari/*.*'
    #
    # @note Idempotent: re-anonymizing already-anonymized output is a no-op, so
    #   a UA reduced at the edge and one reduced again downstream agree.
    class UserAgentPrivacy
      # Default cap on the returned string, guarding against a DoS via a huge
      # User-Agent header. Matches the length RedactedFingerprint has always
      # applied.
      DEFAULT_MAX_LENGTH = 500

      # Anonymize a User-Agent string.
      #
      # Removes build identifiers (e.g. +Build/MRA58N+) and version numbers
      # (+*.*.*.*+, +*.*.*+, +*.*+; dot- or underscore-separated), then
      # truncates to +max_length+. Browser/OS family text is preserved -- the
      # point is a partial, not a full redaction.
      #
      # Build identifiers are stripped BEFORE versions: if versions went first,
      # a token like +Build/MPJ24.139-64+ would become +Build/MPJ*.*-64+ and the
      # build regex (which matches only +[\w.-]+) would no longer catch it.
      #
      # @param ua [String, nil] the raw User-Agent string.
      # @param max_length [Integer] maximum length of the returned string.
      # @return [String, nil] the anonymized UA, or nil for nil/empty input.
      def self.anonymize(ua, max_length: DEFAULT_MAX_LENGTH)
        return nil if ua.nil? || ua.empty?

        # Remove build identifiers (e.g., Build/MRA58N, Build/MPJ24.139-64).
        # Must run BEFORE version stripping (see method note).
        anonymized = ua.gsub(%r{Build/[\w.-]+}, 'Build/*')

        # Remove version patterns (*.*.*.*, *.*.*, *.*), longest first.
        # Support both dot and underscore separators (e.g. 10.15.7 and 10_15_7).
        anonymized = anonymized
                     .gsub(/\d+[._]\d+[._]\d+[._]\d+/, '*.*.*.*')
                     .gsub(/\d+[._]\d+[._]\d+/, '*.*.*')
                     .gsub(/\d+[._]\d+/, '*.*')

        # Truncate if too long (prevent DoS via huge UA strings).
        anonymized.length > max_length ? anonymized[0...max_length] : anonymized
      end
    end
  end
end
