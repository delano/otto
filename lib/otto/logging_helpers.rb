# frozen_string_literal: true

# lib/otto/logging_helpers.rb

class Otto
  # LoggingHelpers provides utility methods for consistent structured logging
  # across the Otto framework. Centralizes common request context extraction
  # to eliminate duplication while keeping logging calls simple and explicit.
  module LoggingHelpers
    # Structured logging helpers for Otto framework.
    #
    # BASE CONTEXT PATTERN (recommended for downstream projects):
    #
    # Create base context once per error/event, then merge event-specific fields.
    #
    # THREAD SAFETY: This pattern is thread-safe for concurrent requests. Each
    # request has its own `env` hash, so `request_context(env)` creates isolated
    # context hashes per request. The pattern extracts immutable values (strings,
    # symbols) from `env`, and `.merge()` creates new hashes rather than mutating
    # shared state. Safe for use in multi-threaded Rack servers (Puma, Falcon).
    #
    #   base_context = Otto::LoggingHelpers.request_context(env)
    #
    #   Otto.structured_log(:error, "Handler failed",
    #     base_context.merge(
    #       error: error.message,
    #       error_class: error.class.name,
    #       error_id: error_id,
    #       duration: duration
    #     )
    #   )
    #
    #   Otto::LoggingHelpers.log_backtrace(error,
    #     base_context.merge(error_id: error_id, handler: 'Controller#action')
    #   )
    #
    # DOWNSTREAM EXTENSIBILITY:
    #
    # Large projects can inject custom shared fields:
    #
    #   custom_base = Otto::LoggingHelpers.request_context(env).merge(
    #     transaction_id: Thread.current[:transaction_id],
    #     user_id: env['otto.user']&.id,
    #     tenant_id: env['tenant_id']
    #   )
    #
    #   Otto.structured_log(:error, "Business operation failed",
    #     custom_base.merge(
    #       error: error.message,
    #       error_class: error.class.name,
    #       account_id: account.id,
    #       operation: :withdrawal
    #     )
    #   )
    #

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

    # Log exception backtrace with correlation fields for debugging.
    # Only logs when Otto.debug is enabled. Limits to first 10 lines.
    #
    # Expects caller to provide correlation context (error_id, handler, etc).
    # Does NOT duplicate error/error_class fields - those belong in main error log.
    #
    # @param error [Exception] The exception to log backtrace for
    # @param context [Hash] Correlation fields (error_id, method, path, ip, handler, etc)
    #
    # @example Basic usage
    #   Otto::LoggingHelpers.log_backtrace(error,
    #     base_context.merge(error_id: error_id, handler: 'UserController#create')
    #   )
    #
    # @example Downstream extensibility
    #   custom_context = Otto::LoggingHelpers.request_context(env).merge(
    #     error_id: error_id,
    #     transaction_id: Thread.current[:transaction_id],
    #     tenant_id: env['tenant_id']
    #   )
    #   Otto::LoggingHelpers.log_backtrace(error, custom_context)
    #
    def self.log_backtrace(error, context = {})
      return unless Otto.debug

      backtrace = error.backtrace&.first(10) || []
      Otto.structured_log(:debug, "Exception backtrace",
        context.merge(backtrace: backtrace)
      )
    end

  end
end
