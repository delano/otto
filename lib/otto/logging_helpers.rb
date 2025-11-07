# lib/otto/logging_helpers.rb
#
# frozen_string_literal: true

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
                ip: env['REMOTE_ADDR'], # Already masked by IPPrivacyMiddleware for public IPs
           country: env['otto.geo_country'],
        user_agent: env['HTTP_USER_AGENT']&.slice(0, 100), # Already anonymized by IPPrivacyMiddleware
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
    def self.log_timed_operation(level, message, env, **metadata)
      start_time = Otto::Utils.now_in_μs
      result = yield
      duration = Otto::Utils.now_in_μs - start_time

      Otto.structured_log(level, message,
        request_context(env).merge(metadata).merge(duration: duration))

      result
    rescue StandardError => e
      duration = Otto::Utils.now_in_μs - start_time
      Otto.structured_log(:error, "#{message} failed",
        request_context(env).merge(metadata).merge(
          duration: duration,
          error: e.message,
          error_class: e.class.name
        ))
      raise
    end

    # Detect project root directory for path sanitization
    # @return [String] Absolute path to project root
    def self.detect_project_root
      @project_root ||= begin
        if defined?(Bundler)
          Bundler.root.to_s
        else
          Dir.pwd
        end
      end
    end

    # Sanitize a single backtrace line to remove sensitive path information
    #
    # Transforms absolute paths into relative or categorized paths:
    # - Project files: relative path from project root
    # - Gem files: [GEM] gem-name-version/relative/path
    # - Ruby stdlib: [RUBY] filename
    # - Unknown: [EXTERNAL] filename
    #
    # @param line [String] Raw backtrace line
    # @param project_root [String] Project root path (auto-detected if nil)
    # @return [String] Sanitized backtrace line
    #
    # @example
    #   sanitize_backtrace_line("/Users/admin/app/lib/user.rb:42:in `save'")
    #   # => "lib/user.rb:42:in `save'"
    #
    #   sanitize_backtrace_line("/usr/local/gems/rack-3.1.8/lib/rack.rb:10")
    #   # => "[GEM] rack-3.1.8/lib/rack.rb:10"
    #
    def self.sanitize_backtrace_line(line, project_root = nil)
      return line if line.nil? || line.empty?

      project_root ||= detect_project_root
      expanded_root = File.expand_path(project_root)

      # Extract file path from backtrace line (format: "path:line:in `method'" or "path:line")
      if line =~ /^(.+?):\d+(?::in `.+')?$/
        file_path = ::Regexp.last_match(1)
        suffix = line[file_path.length..]

        begin
          expanded_path = File.expand_path(file_path)
        rescue ArgumentError
          # Handle malformed paths (e.g., containing null bytes)
          # File.basename also raises ArgumentError for null bytes, so use simple string manipulation
          basename = file_path.split('/').last || file_path
          return "[EXTERNAL] #{basename}#{suffix}"
        end

        # Try project-relative path first
        if expanded_path.start_with?(expanded_root + File::SEPARATOR)
          relative_path = expanded_path.delete_prefix(expanded_root + File::SEPARATOR)
          return relative_path + suffix
        end

        # Check for gem path (e.g., /path/to/gems/rack-3.1.8/lib/rack.rb)
        if expanded_path =~ %r{/gems/([^/]+)/(.+)$}
          gem_name = ::Regexp.last_match(1)
          gem_relative = ::Regexp.last_match(2)
          return "[GEM] #{gem_name}/#{gem_relative}#{suffix}"
        end

        # Check for Ruby stdlib (e.g., /path/to/ruby/3.4.0/logger.rb)
        if expanded_path =~ %r{/ruby/[\d.]+/(.+)$}
          stdlib_file = ::Regexp.last_match(1)
          return "[RUBY] #{stdlib_file}#{suffix}"
        end

        # Unknown/external path - show filename only
        filename = File.basename(file_path)
        return "[EXTERNAL] #{filename}#{suffix}"
      end

      # Couldn't parse - return as-is (better than failing)
      line
    end

    # Sanitize an array of backtrace lines
    #
    # @param backtrace [Array<String>] Raw backtrace lines
    # @param project_root [String] Project root path (auto-detected if nil)
    # @return [Array<String>] Sanitized backtrace lines
    def self.sanitize_backtrace(backtrace, project_root: nil)
      return [] if backtrace.nil? || backtrace.empty?

      project_root ||= detect_project_root
      backtrace.map { |line| sanitize_backtrace_line(line, project_root) }
    end

    # Log exception backtrace with correlation fields for debugging.
    # Always logs for unhandled errors at ERROR level with sanitized paths.
    # Limits to first 20 lines for critical errors.
    #
    # SECURITY: Paths are sanitized to prevent exposing sensitive system information:
    # - Project files: Show relative paths only
    # - Gem files: Show gem name and relative path within gem
    # - Ruby stdlib: Show filename only
    # - External files: Show filename only
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
      raw_backtrace = error.backtrace&.first(20) || []
      sanitized = sanitize_backtrace(raw_backtrace)

      Otto.structured_log(:error, 'Exception backtrace',
        context.merge(backtrace: sanitized))
    end
  end
end
