# frozen_string_literal: true

# lib/otto/logging_helpers.rb

class Otto
  # LoggingHelpers provides utility methods for consistent structured logging
  # across the Otto framework. Centralizes common request context extraction
  # to eliminate duplication while keeping logging calls simple and explicit.
  module LoggingHelpers
    # Extract common request context for structured logging
    #
    # Returns a hash containing privacy-aware request metadata suitable
    # for merging with event-specific data in Otto.structured_log calls.
    #
    # @param env [Hash] Rack environment hash
    # @return [Hash] Request context with method, path, ip, country, user_agent
    #
    # @example Basic usage
    #   Otto.structured_log(:info, "Route matched",
    #     Otto::LoggingHelpers.request_context(env).merge(
    #       type: 'literal',
    #       handler: 'App#index'
    #     )
    #   )
    #
    # @note IP addresses are already masked by IPPrivacyMiddleware (public IPs only)
    # @note User agents are truncated to 100 chars to prevent log bloat
    def self.request_context(env)
      {
        method: env['REQUEST_METHOD'],
        path: env['PATH_INFO'],
        ip: env['REMOTE_ADDR'],  # Already masked by IPPrivacyMiddleware for public IPs
        country: env['otto.geo_country'],
        user_agent: env['HTTP_USER_AGENT']&.slice(0, 100)  # Already anonymized by IPPrivacyMiddleware
      }.compact
    end

    # Log a timed operation with consistent timing and error handling
    #
    # @param level [Symbol] The log level (:debug, :info, :warn, :error)
    # @param message [String] The log message
    # @param env [Hash] Rack environment for request context
    # @param metadata [Hash] Additional metadata to include in the log
    # @yield The block to execute and time
    # @return The result of the block
    #
    # @example
    #   Otto::LoggingHelpers.log_timed_operation(:info, "Template compiled", env,
    #     template_type: 'handlebars', cached: false
    #   ) do
    #     compile_template(template)
    #   end
    #
    def self.log_timed_operation(level, message, env, **metadata, &block)
      start_time = Otto::Utils.now_in_μs
      result = yield
      duration = Otto::Utils.now_in_μs - start_time

      Otto.structured_log(level, message,
        request_context(env).merge(metadata).merge(duration: duration)
      )

      result
    rescue StandardError => ex
      duration = Otto::Utils.now_in_μs - start_time
      Otto.structured_log(:error, "#{message} failed",
        request_context(env).merge(metadata).merge(
          duration: duration,
          error: ex.message,
          error_class: ex.class.name
        )
      )
      raise
    end

    # Format a value for key=value log output (like the inspiration example)
    #
    # @param value [Object] The value to format
    # @return [String] Formatted value
    #
    def self.format_value(value)
      case value
      when String
        value.to_s
      when Integer, Float
        value.to_s
      when true, false
        value.to_s
      when nil
        'nil'
      else
        value.inspect
      end
    end

    # Log with key=value format (alternative to structured_log for simple cases)
    #
    # @param level [Symbol] The log level (:debug, :info, :warn, :error)
    # @param message [String] The log message
    # @param metadata [Hash] Key-value pairs to format
    #
    # @example
    #   Otto::LoggingHelpers.log_with_metadata(:info, "Template compiled",
    #     template_type: 'handlebars', cached: false, duration: 68
    #   )
    #   # Output: Template compiled: template_type=handlebars cached=false duration=68
    #
    def self.log_with_metadata(level, message, metadata = {})
      return Otto.structured_log(level, message) if metadata.empty?

      metadata_str = metadata.map { |k, v| "#{k}=#{format_value(v)}" }.join(' ')
      Otto.logger.send(level, "#{message}: #{metadata_str}")
    end
  end
end
