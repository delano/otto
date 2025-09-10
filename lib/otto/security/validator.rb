# frozen_string_literal: true

# lib/otto/security/validator.rb

require 'json'
require 'cgi'
require 'loofah'
require 'facets/file'

require_relative '../helpers/validation'

class Otto
  module Security
    # ValidationMiddleware provides input validation and sanitization for web requests
    # Uses Loofah for HTML/XSS sanitization and Facets for filename sanitization
    class ValidationMiddleware
      # Character validation patterns
      INVALID_CHARACTERS = /[\x00-\x1f\x7f-\xff]/n
      NULL_BYTE          = /\0/

      # HTML/XSS sanitization is handled by Loofah library for better security coverage

      SQL_INJECTION_PATTERNS = [
        /('|(\\')|(;)|(\\)|(--)|(%27)|(%3B)|(%3D))/i,
        /(union|select|insert|update|delete|drop|create|alter|exec|execute)/i,
        /(or|and)\s+\w+\s*=\s*\w+/i,
        /\d+\s*(=|>|<|>=|<=|<>|!=)\s*\d+/i,
      ].freeze

      def initialize(app, config = nil)
        @app    = app
        @config = config || Otto::Security::Config.new
      end

      def call(env)
        return @app.call(env) unless @config.input_validation

        request = Rack::Request.new(env)

        begin
          # Validate request size
          validate_request_size(request)

          # Validate content type
          validate_content_type(request)

          # Validate and sanitize parameters
          begin
            validate_parameters(request) if request.params
          rescue Rack::QueryParser::QueryLimitError => e
            # Handle Rack's built-in query parsing limits
            raise Otto::Security::ValidationError, "Parameter structure too complex: #{e.message}"
          end

          # Validate headers
          validate_headers(request)

          @app.call(env)
        rescue Otto::Security::ValidationError => e
          validation_error_response(e.message)
        rescue Otto::Security::RequestTooLargeError => e
          request_too_large_response(e.message)
        end
      end

      private

      def validate_request_size(request)
        content_length = request.env['CONTENT_LENGTH']
        @config.validate_request_size(content_length)
      end

      def validate_content_type(request)
        content_type = request.env['CONTENT_TYPE']
        return unless content_type

        # Block dangerous content types
        dangerous_types = [
          'application/x-shockwave-flash',
          'application/x-silverlight-app',
          'text/vbscript',
          'application/vbscript',
        ]

        return unless dangerous_types.any? { |type| content_type.downcase.include?(type) }

        raise Otto::Security::ValidationError, "Dangerous content type: #{content_type}"
      end

      def validate_parameters(request)
        validate_param_structure(request.params, 0)
        sanitize_params(request.params)
      end

      def validate_param_structure(params, depth = 0)
        if depth >= @config.max_param_depth
          raise Otto::Security::ValidationError, "Parameter depth exceeds maximum (#{@config.max_param_depth})"
        end

        case params
        when Hash
          if params.keys.length > @config.max_param_keys
            raise Otto::Security::ValidationError,
                  "Too many parameters (#{params.keys.length} > #{@config.max_param_keys})"
          end

          params.each do |key, value|
            validate_param_key(key)
            validate_param_structure(value, depth + 1) if value.is_a?(Hash) || value.is_a?(Array)
          end
        when Array
          if params.length > @config.max_param_keys
            raise Otto::Security::ValidationError,
                  "Too many array elements (#{params.length} > #{@config.max_param_keys})"
          end

          params.each do |value|
            validate_param_structure(value, depth + 1) if value.is_a?(Hash) || value.is_a?(Array)
          end
        end
      end

      def validate_param_key(key)
        key_str = key.to_s

        # Check for dangerous characters in parameter names using shared patterns
        if key_str.match?(NULL_BYTE) || key_str.match?(INVALID_CHARACTERS)
          raise Otto::Security::ValidationError, "Invalid characters in parameter name: #{key_str}"
        end

        # Check for suspiciously long parameter names
        return unless key_str.length > 256

        raise Otto::Security::ValidationError, "Parameter name too long: #{key_str[0..50]}..."
      end

      def sanitize_params(params)
        case params
        when Hash
          params.each do |key, value|
            params[key] = sanitize_value(value)
          end
        when Array
          params.map! { |value| sanitize_value(value) }
        else
          sanitize_value(params)
        end
      end

      def sanitize_value(value)
        return value unless value.is_a?(String)

        # Check for extremely long values first
        if value.length > 10_000
          raise Otto::Security::ValidationError, "Parameter value too long (#{value.length} characters)"
        end

        # Start with the original value
        original = value.dup

        # Check for null bytes first (these should be rejected, not sanitized)
        raise Otto::Security::ValidationError, 'Dangerous content detected in parameter' if original.match?(NULL_BYTE)

        # Check for script injection first (these should always be rejected)
        if looks_like_script_injection?(original)
          raise Otto::Security::ValidationError, 'Dangerous content detected in parameter'
        end

        # Use Loofah to sanitize HTML/XSS content for less dangerous HTML
        # Loofah.fragment removes dangerous HTML but preserves safe content
        sanitized = Loofah.fragment(original).scrub!(:whitewash).to_s

        # Remove control characters (sanitize, don't block)
        sanitized = sanitized.gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, '')

        # Check for SQL injection patterns
        SQL_INJECTION_PATTERNS.each do |pattern|
          raise Otto::Security::ValidationError, 'Potential SQL injection detected' if sanitized.match?(pattern)
        end

        sanitized
      end

      include ValidationHelpers

      def validate_headers(request)
        # Check for dangerous headers
        dangerous_headers = %w[
          HTTP_X_FORWARDED_HOST
          HTTP_X_ORIGINAL_URL
          HTTP_X_REWRITE_URL
          HTTP_DESTINATION
          HTTP_UPGRADE_INSECURE_REQUESTS
        ]

        dangerous_headers.each do |header|
          value = request.env[header]
          next unless value

          # Basic validation - no null bytes or control characters
          if value.match?(NULL_BYTE) || value.match?(INVALID_CHARACTERS)
            raise Otto::Security::ValidationError, "Invalid characters in header: #{header}"
          end
        end

        # Validate User-Agent length
        user_agent = request.env['HTTP_USER_AGENT']
        raise Otto::Security::ValidationError, 'User-Agent header too long' if user_agent && user_agent.length > 1000

        # Validate Referer header
        referer = request.env['HTTP_REFERER']
        return unless referer && referer.length > 2000

        raise Otto::Security::ValidationError, 'Referer header too long'
      end

      def validation_error_response(message)
        [
          400,
          {
            'content-type' => 'application/json',
            'content-length' => validation_error_body(message).bytesize.to_s,
          },
          [validation_error_body(message)],
        ]
      end

      def request_too_large_response(message)
        [
          413,
          {
            'content-type' => 'application/json',
            'content-length' => request_too_large_body(message).bytesize.to_s,
          },
          [request_too_large_body(message)],
        ]
      end

      def validation_error_body(message)
        require 'json'
        {
          error: 'Validation failed',
          message: message,
        }.to_json
      end

      def request_too_large_body(message)
        require 'json'
        {
          error: 'Request too large',
          message: message,
        }.to_json
      end
    end
  end
end
