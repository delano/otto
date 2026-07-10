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
      # HTTP methods that never mutate state and so are exempt from token
      # validation (RFC 7231 safe methods plus TRACE).
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
        # Reject nil / blank / whitespace-only tokens up front, before creating
        # a session or running HMAC verification — obviously-malformed input
        # should not cause session churn (#186 review).
        return false if token.nil? || token.strip.empty?

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

      def extract_session_id(request)
        @config.get_or_create_session_id(request)
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
