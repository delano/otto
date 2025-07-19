# lib/otto/security/csrf.rb

require 'securerandom'

class Otto
  module Security
    class CSRFMiddleware
      SAFE_METHODS = %w[GET HEAD OPTIONS TRACE].freeze

      def initialize(app, config = nil)
        @app = app
        @config = config || Otto::Security::Config.new
      end

      def call(env)
        return @app.call(env) unless @config.csrf_enabled?

        request = Rack::Request.new(env)

        # Skip CSRF protection for safe methods
        if safe_method?(request.request_method)
          response = @app.call(env)
          response = inject_csrf_token(request, response) if html_response?(response)
          return response
        end

        # Validate CSRF token for unsafe methods
        unless valid_csrf_token?(request)
          return csrf_error_response
        end

        @app.call(env)
      end

      private

      def safe_method?(method)
        SAFE_METHODS.include?(method.upcase)
      end

      def valid_csrf_token?(request)
        token = extract_csrf_token(request)
        return false if token.nil? || token.empty?

        session_id = @config.get_or_create_session_id(request)
        @config.verify_csrf_token(token, session_id)
      end

      def extract_csrf_token(request)
        # Try form parameter first
        token = request.params[@config.csrf_token_key]

        # Try header if not in params
        token ||= request.env[@config.csrf_header_key]

        # Try alternative header format
        token ||= request.env['HTTP_X_REQUESTED_WITH'] == 'XMLHttpRequest' ?
                    request.env['HTTP_X_CSRF_TOKEN'] : nil

        token
      end

      def extract_session_id(request)
        @config.get_or_create_session_id(request)
      end

      def inject_csrf_token(request, response)
        return response unless response.is_a?(Array) && response.length >= 3

        status, headers, body = response
        content_type = headers.find { |k, v| k.downcase == 'content-type' }&.last

        return response unless content_type&.include?('text/html')

        # Get or create session ID
        session_id =  @config.get_or_create_session_id(request)

        # Generate new CSRF token
        csrf_token = @config.generate_csrf_token(session_id)

        # Inject meta tag into HTML head
        body_content = body.respond_to?(:join) ? body.join : body.to_s

        if body_content.match?(/<head>/i)
          meta_tag = %(<meta name="csrf-token" content="#{csrf_token}">)
          body_content = body_content.sub(/<head>/i, "<head>\n#{meta_tag}")

          # Update content length if present
          content_length_key = headers.keys.find { |k| k.downcase == 'content-length' }
          if content_length_key
            headers[content_length_key] = body_content.bytesize.to_s
          end

          [status, headers, [body_content]]
        else
          response
        end
      end

      def html_response?(response)
        return false unless response.is_a?(Array) && response.length >= 2

        headers = response[1]
        content_type = headers.find { |k, v| k.downcase == 'content-type' }&.last
        content_type&.include?('text/html')
      end

      def csrf_error_response
        [
          403,
          {
            'content-type' => 'application/json',
            'content-length' => csrf_error_body.bytesize.to_s
          },
          [csrf_error_body]
        ]
      end

      def csrf_error_body
        {
          error: 'CSRF token validation failed',
          message: 'The request could not be authenticated. Please refresh the page and try again.'
        }.to_json
      end

    end

    module CSRFHelpers
      def csrf_token
        if @csrf_token.nil? && otto.respond_to?(:security_config)
          session_id = otto.security_config.get_or_create_session_id(req)
          @csrf_token = otto.security_config.generate_csrf_token(session_id)
        end
        @csrf_token
      end

      private

      public

      def csrf_meta_tag
        %(<meta name="csrf-token" content="#{csrf_token}">)
      end

      def csrf_form_tag
        %(<input type="hidden" name="#{csrf_token_key}" value="#{csrf_token}">)
      end

      def csrf_token_key
        otto.respond_to?(:security_config) ?
          otto.security_config.csrf_token_key : '_csrf_token'
      end
    end
  end
end
