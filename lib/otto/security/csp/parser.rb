# lib/otto/security/csp/parser.rb
#
# frozen_string_literal: true

require 'json'

require_relative 'report'

class Otto
  module Security
    module CSP
      # Parses inbound Content-Security-Policy violation report bodies into a
      # list of normalized {Otto::Security::CSP::Report} objects.
      #
      # Handles BOTH standardized wire formats:
      #
      # - Legacy `application/csp-report` — a single JSON object
      #   `{"csp-report": { ... }}`.
      # - Reporting API `application/reports+json` — a JSON ARRAY of
      #   `{"type": "csp-violation", "body": { ... }}` entries (a single
      #   un-wrapped object is tolerated too).
      #
      # The parser keys off the JSON SHAPE rather than trusting the declared
      # `Content-Type`, because browsers and intermediaries are inconsistent
      # about the header. The `content_type` argument is accepted for future use
      # and symmetry with the middleware but is not currently required to
      # disambiguate.
      #
      # It is intentionally TOTAL: malformed JSON, an unexpected top-level type,
      # or entries that are not CSP violations yield an empty array rather than
      # raising. A violation-report receiver must never fail on hostile input.
      module Parser
        module_function

        # Parse a raw report body into normalized reports.
        #
        # @param body [String, nil] the raw request body (JSON).
        # @param content_type [String, nil] the request Content-Type (hint only).
        # @return [Array<Otto::Security::CSP::Report>] zero or more normalized
        #   reports. Empty when the body is nil/blank/malformed or contains no
        #   recognizable CSP violations.
        def parse(body, content_type = nil)
          return [] if body.nil? || body.empty?

          data = safe_json_parse(body)
          return [] if data.nil?

          extract_raw_reports(data, content_type).filter_map do |raw|
            Report.from_raw(raw)
          end
        end

        # Parse JSON, swallowing the errors a hostile/garbled body can throw.
        #
        # @param body [String]
        # @return [Object, nil] the parsed structure, or nil on any parse error.
        def safe_json_parse(body)
          JSON.parse(body)
        rescue JSON::ParserError, EncodingError
          nil
        end

        # Pull the per-violation field hashes out of either wire format.
        #
        # @param data [Object] the parsed JSON structure.
        # @param _content_type [String, nil] unused (shape drives extraction).
        # @return [Array<Hash>] raw, un-normalized per-violation field hashes.
        def extract_raw_reports(data, _content_type = nil)
          case data
          when Array
            extract_from_reporting_api(data)
          when Hash
            extract_from_object(data)
          else
            []
          end
        end

        # Reporting API batch: an array of report envelopes. Keep entries that
        # are (or are untyped but shaped like) CSP violations and carry a body.
        #
        # @param entries [Array]
        # @return [Array<Hash>]
        def extract_from_reporting_api(entries)
          entries.filter_map do |entry|
            next unless entry.is_a?(Hash)

            body = entry['body']
            next unless body.is_a?(Hash)

            type = entry['type']
            # Accept entries explicitly typed csp-violation, or untyped bodies.
            # Skip other report types (deprecation, intervention, ...).
            next unless type.nil? || type == 'csp-violation'

            body
          end
        end

        # A single top-level object in either the legacy `{"csp-report": {...}}`
        # envelope or a lone Reporting API `{"type":..., "body": {...}}` object.
        #
        # @param data [Hash]
        # @return [Array<Hash>]
        def extract_from_object(data)
          if data['csp-report'].is_a?(Hash)
            [data['csp-report']]
          elsif data['body'].is_a?(Hash)
            [data['body']]
          else
            []
          end
        end
      end
    end
  end
end
