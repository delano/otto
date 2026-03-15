# lib/otto/locale/middleware.rb
#
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
      # @param fallback_locale [Hash, nil] Hash of locale codes to fallback chains
      # @param debug [Boolean] Enable debug logging
      def initialize(app, available_locales:, default_locale:, fallback_locale: nil, debug: false)
        @app = app
        @available_locales = available_locales
        @default_locale = default_locale
        @fallback_locale = fallback_locale
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
        req = Otto::Request.new(env)
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

      # Parse Accept-Language header with RFC 2616 quality value support
      #
      # Handles formats like:
      # - "en-US,en;q=0.9,fr;q=0.8" → finds first available from [en, en, fr]
      # - "es,en;q=0.9" → returns "en" if "es" unavailable but "en" is
      # - "fr-FR" → "fr_FR" (exact match with region) or "fr" (fallback)
      # - "pt-BR,en;q=0.9" → "pt_BR" if available
      #
      # Resolution order per tag (via resolve_locale):
      # 1. Exact match with region (fr-FR → fr_FR)
      # 2. Fallback chain (if configured)
      # 3. Primary language code (fr-FR → fr)
      #
      # Respects q-values (quality factors) and returns the highest-priority
      # available locale instead of just the first language tag.
      #
      # @param header [String, nil] Accept-Language header value
      # @return [String, nil] Best matching available locale code or nil
      def parse_accept_language(header)
        return nil unless header

        # Parse all language tags with their q-values
        # Format: "en-US,en;q=0.9,fr;q=0.8" → [[en-US, 1.0], [en, 0.9], [fr, 0.8]]
        languages = header.split(',').map do |tag|
          # Split on semicolon and extract q-value
          parts = tag.strip.split(/\s*;\s*q\s*=\s*/)
          locale_str = parts[0]
          q_value = parts[1] ? parts[1].to_f : 1.0
          [locale_str, q_value]
        end

        # Sort by q-value descending (highest preference first)
        # and resolve each tag against available_locales
        languages.sort_by { |_, q| -q }.each do |lang_tag, _|
          resolved = resolve_locale(lang_tag)
          return resolved if resolved
        end

        nil # No matching locale found
      rescue StandardError => ex
        Otto.logger&.warn "[Otto::Locale] Failed to parse Accept-Language: #{ex.message}"
        nil
      end

      # Resolve a single language tag against available locales
      #
      # Resolution order:
      # 1. Exact match with region (fr-FR → fr_FR)
      # 2. Fallback chain (if configured)
      # 3. Primary language code (fr-FR → fr)
      #
      # @param lang_tag [String] BCP 47 language tag (e.g. "fr-FR", "en")
      # @return [String, nil] Matched locale code or nil
      def resolve_locale(lang_tag)
        # Step 1: Exact match — convert HTTP format to locale format (fr-FR → fr_FR)
        normalized = lang_tag.strip.tr('-', '_')
        return normalized if valid_locale?(normalized)
        return normalized.downcase if valid_locale?(normalized.downcase)

        # Step 2: Fallback chain (if configured)
        resolved = resolve_fallback_chain(normalized)
        return resolved if resolved

        # Step 3: Primary language code (fr-FR → fr)
        primary = lang_tag.split('-').first.downcase
        return primary if valid_locale?(primary)

        nil
      end

      # Consult fallback chain for a normalized locale tag
      #
      # @param normalized [String] Normalized locale tag (e.g. "fr_FR")
      # @return [String, nil] First matching fallback locale or nil
      def resolve_fallback_chain(normalized)
        return nil unless @fallback_locale

        chain = @fallback_locale[normalized] || @fallback_locale[normalized.downcase]
        return nil unless chain

        chain.find { |fallback| valid_locale?(fallback) }
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
