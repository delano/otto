# frozen_string_literal: true

class Otto
  module Locale
    # Locale detection and resolution middleware
    #
    # Sets env['otto.locale'] based on:
    # 1. URL parameter (?locale=es)
    # 2. Session preference (session['locale'])
    # 3. HTTP Accept-Language header
    # 4. Default locale
    #
    # Configuration:
    #   use Otto::Locale::Middleware,
    #     available_locales: { 'en' => 'English', 'es' => 'Spanish' },
    #     default_locale: 'en',
    #     debug: false
    #
    # @example Basic usage
    #   use Otto::Locale::Middleware,
    #     available_locales: { 'en' => 'English', 'es' => 'Español', 'fr' => 'Français' },
    #     default_locale: 'en'
    #
    # @example With session persistence
    #   use Rack::Session::Cookie, secret: 'secret'
    #   use Otto::Locale::Middleware,
    #     available_locales: { 'en' => 'English', 'es' => 'Español' },
    #     default_locale: 'en'
    #
    class Middleware
      attr_reader :available_locales, :default_locale

      # Initialize locale middleware
      #
      # @param app [#call] Rack application
      # @param available_locales [Hash<String, String>] Hash of locale codes to language names
      # @param default_locale [String] Default locale code
      # @param debug [Boolean] Enable debug logging
      def initialize(app, available_locales:, default_locale:, debug: false)
        @app = app
        @available_locales = available_locales
        @default_locale = default_locale
        @debug = debug

        validate_config!
      end

      # Process request and set locale
      #
      # @param env [Hash] Rack environment
      # @return [Array] Rack response tuple [status, headers, body]
      def call(env)
        locale = detect_locale(env)
        env['otto.locale'] = locale

        debug_log(env, locale) if @debug

        @app.call(env)
      end

      private

      # Detect locale using priority chain
      #
      # @param env [Hash] Rack environment
      # @return [String] Resolved locale code
      def detect_locale(env)
        # 1. Check URL parameter
        req = Rack::Request.new(env)
        locale = req.params['locale']
        return locale if valid_locale?(locale)

        # 2. Check session
        session = env['rack.session']
        locale = session['locale'] if session
        return locale if valid_locale?(locale)

        # 3. Parse Accept-Language header
        locale = parse_accept_language(env['HTTP_ACCEPT_LANGUAGE'])
        return locale if valid_locale?(locale)

        # 4. Default
        @default_locale
      end

      # Parse Accept-Language header
      #
      # Handles formats like:
      # - "en-US,en;q=0.9,fr;q=0.8" → "en"
      # - "es" → "es"
      # - "fr-CA" → "fr"
      #
      # @param header [String, nil] Accept-Language header value
      # @return [String, nil] Locale code or nil
      def parse_accept_language(header)
        return nil unless header

        # Parse "en-US,en;q=0.9,fr;q=0.8" → "en"
        lang = header.split(',').first
        return nil unless lang

        # Extract language code before hyphen or semicolon
        lang.split(/[-;]/).first.downcase
      rescue StandardError => ex
        Otto.logger&.warn "[Otto::Locale] Failed to parse Accept-Language: #{ex.message}"
        nil
      end

      # Check if locale is valid
      #
      # @param locale [String, nil] Locale code to validate
      # @return [Boolean] true if locale is in available_locales
      def valid_locale?(locale)
        return false unless locale
        @available_locales.key?(locale.to_s)
      end

      # Validate middleware configuration
      #
      # @raise [ArgumentError] if configuration is invalid
      def validate_config!
        raise ArgumentError, 'available_locales must be a Hash' unless @available_locales.is_a?(Hash)
        raise ArgumentError, 'available_locales cannot be empty' if @available_locales.empty?
        raise ArgumentError, 'default_locale must be in available_locales' unless @available_locales.key?(@default_locale)
      end

      # Log debug information about locale detection
      #
      # @param env [Hash] Rack environment
      # @param locale [String] Resolved locale
      def debug_log(env, locale)
        Otto.logger&.debug format(
          '[Otto::Locale] Selected locale=%s (param=%s session=%s header=%s)',
          locale,
          Rack::Request.new(env).params['locale'] || 'nil',
          env['rack.session']&.dig('locale') || 'nil',
          env['HTTP_ACCEPT_LANGUAGE']&.split(',')&.first || 'nil'
        )
      end
    end
  end
end
