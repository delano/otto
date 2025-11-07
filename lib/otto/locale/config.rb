# lib/otto/locale/config.rb

# lib/otto/locale/config.rb

require_relative '../core/freezable'

class Otto
  module Locale
    # Locale configuration for Otto applications
    #
    # This class manages locale-related settings including available locales
    # and default locale selection.
    #
    # @example Basic usage
    #   config = Otto::Locale::Config.new
    #   config.available_locales = { 'en' => 'English', 'es' => 'Spanish' }
    #   config.default_locale = 'en'
    #
    # @example With initialization
    #   config = Otto::Locale::Config.new(
    #     available_locales: { 'en' => 'English', 'fr' => 'French' },
    #     default_locale: 'en'
    #   )
    class Config
      include Otto::Core::Freezable

      attr_accessor :available_locales, :default_locale

      # Initialize locale configuration
      #
      # @param available_locales [Hash, nil] Hash of locale codes to names
      # @param default_locale [String, nil] Default locale code
      def initialize(available_locales: nil, default_locale: nil)
        @available_locales = available_locales
        @default_locale = default_locale
      end

      # Convert to hash for compatibility with existing code
      #
      # @return [Hash] Hash representation of configuration
      def to_h
        {
          available_locales: @available_locales,
          default_locale: @default_locale,
        }.compact
      end

      # Check if locale configuration is present
      #
      # @return [Boolean] true if either available_locales or default_locale is set
      def configured?
        !@available_locales.nil? || !@default_locale.nil?
      end
    end
  end
end
