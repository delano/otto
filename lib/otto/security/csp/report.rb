# lib/otto/security/csp/report.rb
#
# frozen_string_literal: true

class Otto
  module Security
    module CSP
      # A single, normalized Content-Security-Policy violation report.
      #
      # Browsers emit violation reports in two different wire formats with two
      # different field-naming conventions:
      #
      # - Legacy `application/csp-report` (CSP Level 2/3): a JSON object under a
      #   `"csp-report"` key using kebab-case fields (`blocked-uri`,
      #   `violated-directive`, `line-number`, ...).
      # - Reporting API `application/reports+json` (Reporting API v1): a JSON
      #   ARRAY of `{"type": "csp-violation", "body": {...}}` entries whose body
      #   uses camelCase fields (`blockedURL`, `effectiveDirective`,
      #   `lineNumber`, ...).
      #
      # This Struct is the single normalized shape both formats collapse into, so
      # application callbacks registered via
      # {Otto::Security::Config#on_csp_violation} never have to care which format
      # the browser used. Build instances with {.from_raw}; use {#to_h} to
      # serialize.
      #
      # SECURITY NOTE: the URL-ish fields (`document_uri`, `blocked_uri`,
      # `referrer`, `source_file`) reflect the page the browser was on and the
      # resource it tried to load. In some applications these can carry sensitive
      # path/query data (tokens, secret links). Otto does NOT redact these — it
      # normalizes and hands them to your callback verbatim. If your application
      # logs or forwards reports, redact these fields in your callback per your
      # own privacy policy before they reach a log sink.
      #
      # @example Reading fields in a callback
      #   config.on_csp_violation do |report|
      #     logger.warn("CSP violation: #{report.violated_directive} " \
      #                 "blocked #{report.blocked_uri}")
      #   end
      Report = Struct.new(
        :document_uri,
        :referrer,
        :blocked_uri,
        :violated_directive,
        :effective_directive,
        :original_policy,
        :disposition,
        :source_file,
        :status_code,
        :script_sample,
        :line_number,
        :column_number,
        keyword_init: true
      )

      # Normalization behavior for {Report}. Reopened (rather than defined inside
      # the Struct.new block) so the constants below are plain class constants,
      # not constants-defined-in-a-block.
      class Report
        # Map from a normalized field to the list of raw keys (in priority order)
        # that may hold its value across both wire formats. Legacy kebab-case
        # keys are listed alongside their Reporting API camelCase equivalents.
        FIELD_ALIASES = {
                 document_uri:        %w[document-uri documentURL],
                     referrer:        %w[referrer referer],
                  blocked_uri:        %w[blocked-uri blockedURL],
           violated_directive:        %w[violated-directive violatedDirective],
          effective_directive:        %w[effective-directive effectiveDirective],
              original_policy:        %w[original-policy originalPolicy],
                  disposition:        %w[disposition],
                  source_file:        %w[source-file sourceFile],
                  status_code:        %w[status-code statusCode],
                script_sample:        %w[script-sample sample],
                  line_number:        %w[line-number lineNumber],
                column_number:        %w[column-number columnNumber],
        }.freeze

        # Fields coerced to an Integer (or nil) rather than kept as whatever
        # scalar the browser sent.
        NUMERIC_FIELDS = %i[status_code line_number column_number].freeze

        # Build a normalized Report from a single raw per-violation field hash.
        #
        # Accepts either wire format's field naming. `violated_directive` and
        # `effective_directive` are cross-filled from each other when only one is
        # present, because the two formats disagree on which they send (legacy
        # favors `violated-directive`; the Reporting API favors
        # `effectiveDirective`).
        #
        # @param raw [Hash] a single violation's field hash (already unwrapped
        #   from any `csp-report`/`body` envelope by the parser).
        # @return [Report, nil] the normalized report, or nil when `raw` is not a
        #   usable Hash.
        def self.from_raw(raw)
          return nil unless raw.is_a?(Hash)

          attrs = FIELD_ALIASES.each_with_object({}) do |(field, keys), acc|
            value      = first_present(raw, keys)
            acc[field] = NUMERIC_FIELDS.include?(field) ? coerce_int(value) : value
          end

          cross_fill_directives!(attrs)
          new(**attrs)
        end

        # First non-nil value among the given keys, in priority order.
        #
        # @param raw [Hash]
        # @param keys [Array<String>]
        # @return [Object, nil]
        def self.first_present(raw, keys)
          keys.each do |key|
            value = raw[key]
            return value unless value.nil?
          end
          nil
        end

        # Coerce a raw value to an Integer, or nil when it is not a clean
        # integer. Guards against a browser sending a huge or non-numeric value.
        #
        # @param value [Object]
        # @return [Integer, nil]
        def self.coerce_int(value)
          return nil if value.nil?
          return value if value.is_a?(Integer)

          str = value.to_s
          str.match?(/\A-?\d{1,18}\z/) ? str.to_i : nil
        end

        # Populate a missing directive from its sibling so callbacks can rely on
        # both `violated_directive` and `effective_directive` being present when
        # the browser sent at least one.
        #
        # @param attrs [Hash]
        # @return [void]
        def self.cross_fill_directives!(attrs)
          attrs[:violated_directive]  ||= attrs[:effective_directive]
          attrs[:effective_directive] ||= attrs[:violated_directive]
        end

        private_class_method :first_present, :coerce_int, :cross_fill_directives!
      end
    end
  end
end
