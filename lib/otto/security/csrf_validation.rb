# lib/otto/security/csrf_validation.rb
#
# frozen_string_literal: true

require 'json'

class Otto
  module Security
    # Shared CSRF token mechanics.
    #
    # Both the global +CSRFMiddleware+ (which injects tokens into HTML
    # responses) and the per-route +CSRFEnforcementWrapper+ (which enforces
    # tokens on unsafe requests, honoring +csrf=exempt+) mix this in so the
    # two cannot drift on what counts as a safe method, where a token may be
    # carried, or how a rejection is shaped. The including object must expose a
    # +@config+ (an +Otto::Security::Config+).
    module CSRFValidation
      # The request methods RFC 9110, section 9.2.1 defines as safe. They are
      # exempt from token validation.
      SAFE_METHODS = %w[GET HEAD OPTIONS TRACE].freeze

      # Static 403 body. Frozen once so a rejected request does not re-serialize
      # the same JSON on every call.
      CSRF_ERROR_BODY = {
          error: 'CSRF token validation failed',
        message: 'The request could not be authenticated. Please refresh the page and try again.',
      }.to_json.freeze

      private

      def safe_method?(method)
        SAFE_METHODS.include?(method.to_s.upcase)
      end

      def valid_csrf_token?(request)
        token = extract_csrf_token(request)
        # Reject a token that cannot be valid before reading the binding or
        # running HMAC verification (#186 review): a missing value, anything
        # that is not an ASCII String (a valid token is hex), and a blank or
        # whitespace-only String. Rack parses _csrf_token[]= into an Array
        # and _csrf_token[k]= into a Hash, and #strip raises on invalid bytes.
        return false unless token.is_a?(String) && token.ascii_only?
        return false if token.strip.empty?

        session_id = extract_session_id(request)
        @config.verify_csrf_token(token, session_id)
      end

      def extract_csrf_token(request)
        # Try form parameter first
        token = request.params[@config.csrf_token_key]

        # Try header if not in params
        token ||= request.env[@config.csrf_header_key]

        # Try alternative header format
        token ||= request.env['HTTP_X_CSRF_TOKEN'] if request.env['HTTP_X_REQUESTED_WITH'] == 'XMLHttpRequest'

        token
      end

      # The binding to verify against, or nil. A request that has none
      # cannot pass, so none is created for it: behind a session store that
      # write would commit a new session and set its cookie on the 403.
      def extract_session_id(request)
        @config.existing_session_id(request)
      end

      def csrf_error_response
        [
          403,
          {
            'content-type' => 'application/json',
            'content-length' => CSRF_ERROR_BODY.bytesize.to_s,
          },
          [CSRF_ERROR_BODY],
        ]
      end
    end
  end
end
