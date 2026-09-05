# lib/otto/mcp/rate_limiting.rb
#
# frozen_string_literal: true

require 'json'

require_relative '../security/rate_limiting'
require_relative 'endpoint'

class Otto
  module MCP
    # Rate limiter for MCP protocol endpoints
    #
    # Rack::Attack configuration is process-global and a throttle is keyed by
    # name alone, so registering 'mcp_requests' for a second MCP app in the
    # same process used to REPLACE the first app's throttle: the captured
    # endpoint moved from /a to /b and /a stopped being rate limited. Each
    # configured endpoint now gets its own throttle pair
    # ('mcp_requests:/a', 'mcp_tool_calls:/a', ...) with its own limits, and
    # every endpoint configured in the process is remembered in
    # {.registered_endpoints} so the (single, global) throttled responder and
    # log subscriber recognise all of them, not just the most recent.
    #
    # Known limitation: throttles are keyed by endpoint path, not by Otto
    # instance. Two apps in one process that mount MCP on the SAME path (for
    # example both on /_mcp behind a host or tenant dispatcher) share one
    # throttle definition, so the limits configured last apply to both, and
    # one set of per-client-IP counters. Use distinct endpoint paths per app.
    class RateLimiter < Otto::Security::RateLimiting
      DEFAULT_HTTP_ENDPOINT = '/_mcp'

      @endpoints       = Set.new
      @endpoints_mutex = Mutex.new

      class << self
        # Every MCP endpoint configured via {.configure_rack_attack!} in this
        # process, in configuration order.
        # @return [Array<String>]
        def registered_endpoints
          @endpoints_mutex.synchronize { @endpoints.to_a }
        end

        # Forget every registered endpoint. Test isolation only: production
        # configuration is additive for the life of the process, like
        # Rack::Attack's own.
        # @api private
        def reset_endpoints!
          @endpoints_mutex.synchronize { @endpoints.clear }
        end

        # @api private
        def register_endpoint(endpoint)
          return if endpoint.nil?

          @endpoints_mutex.synchronize { @endpoints << endpoint }
        end
      end

      def self.configure_rack_attack!(config = {})
        # Start with base configuration from general rate limiting. The base
        # configure_rack_attack! assigns the single Rack::Attack
        # throttled_responder (dispatching to .throttled_response, overridden
        # below) and calls .configure_logging (also overridden below), so this
        # class registers no responder or subscriber of its own after super.
        super

        register_endpoint(config[:mcp_http_endpoint])
        configure_mcp_rules(config)
      end

      # Resolve the MCP endpoint a Rack::Attack throttle should match against.
      #
      # Rack::Attack is mounted by the hosting app OUTSIDE Otto and runs before
      # every Otto middleware, including the proc that sets
      # env['otto.mcp_http_endpoint'], so inside a throttle that env key is
      # absent. The endpoint therefore has to arrive with the configuration
      # (Server#apply_rate_limits publishes it as :mcp_http_endpoint). The env
      # key is kept as a fallback for callers that run Rack::Attack inside
      # Otto's own stack, and the documented default closes the chain.
      #
      # @param configured [String, nil] endpoint from the rate limiting config
      # @param env [Hash] the request env
      # @return [String]
      def self.mcp_endpoint_for(configured, env)
        configured || env['otto.mcp_http_endpoint'] || DEFAULT_HTTP_ENDPOINT
      end

      # Whether a request targets ANY MCP endpoint configured in this process.
      #
      # Used by the throttled responder and the log subscriber, which are
      # global (the last configuration wins) and so cannot capture a single
      # endpoint the way a per-endpoint throttle can. Consults the registry at
      # call time, then the env key, then the default when nothing is
      # configured at all. A request matches only the exact endpoint path the
      # router would dispatch to the MCP handler (see Otto::MCP.endpoint_path?),
      # never a sibling that merely shares the prefix.
      #
      # Compares PATH_INFO, not Rack::Request#path (SCRIPT_NAME + PATH_INFO):
      # the router dispatches on PATH_INFO, so under `map '/api' { run otto }`
      # the MCP request for an endpoint at /_mcp arrives as SCRIPT_NAME=/api,
      # PATH_INFO=/_mcp and the full path /api/_mcp never equals the endpoint.
      #
      # @param request [Rack::Attack::Request, #path_info, #env]
      # @return [Boolean]
      def self.mcp_request?(request)
        candidates = registered_endpoints
        env_endpoint = request.env['otto.mcp_http_endpoint']
        candidates << env_endpoint if env_endpoint
        candidates << DEFAULT_HTTP_ENDPOINT if candidates.empty?

        candidates.any? { |endpoint| Otto::MCP.endpoint_path?(request.path_info, endpoint) }
      end

      # Name of the Rack::Attack throttle for +rule+ on +endpoint+.
      #
      # The endpoint is part of the name so that two MCP apps in one process
      # get independent throttles (and independent counters: Rack::Attack keys
      # the cache by throttle name). Without a configured endpoint the bare
      # rule name is used and the block resolves the endpoint per request.
      #
      # @param rule [String] 'mcp_requests' or 'mcp_tool_calls'
      # @param endpoint [String, nil]
      # @return [String]
      def self.throttle_name(rule, endpoint)
        endpoint ? "#{rule}:#{endpoint}" : rule
      end

      def self.configure_mcp_rules(config)
        # Captured once, outside the blocks: they run per request, long after
        # this configuration hash is gone.
        configured_endpoint = config[:mcp_http_endpoint]

        # MCP endpoint requests - 60 per minute by default. Only the exact
        # endpoint path counts: the router dispatches the MCP route by literal
        # match, so a prefix match here would let /admin traffic exhaust (and be
        # refused by) the counter for an endpoint at /a. PATH_INFO, not #path:
        # a mount prefix (SCRIPT_NAME) is invisible to the router and must be
        # invisible here too, or a mounted Otto is never throttled.
        mcp_requests_limit = config[:mcp_requests_per_minute] || 60

        Rack::Attack.throttle(throttle_name('mcp_requests', configured_endpoint),
                              limit: mcp_requests_limit, period: 60) do |request|
          endpoint = mcp_endpoint_for(configured_endpoint, request.env)
          request.ip if Otto::MCP.endpoint_path?(request.path_info, endpoint)
        end

        # Tool calls are more expensive - 20 per minute by default
        tool_calls_limit = config[:tool_calls_per_minute] || 20

        Rack::Attack.throttle(throttle_name('mcp_tool_calls', configured_endpoint),
                              limit: tool_calls_limit, period: 60) do |request|
          endpoint = mcp_endpoint_for(configured_endpoint, request.env)
          if Otto::MCP.endpoint_path?(request.path_info, endpoint) && request.post?
            begin
              body = request.body.read
              data = JSON.parse(body)
              request.ip if data['method'] == 'tools/call'
            rescue JSON::ParserError
              nil
            ensure
              request.body.rewind if request.body.respond_to?(:rewind)
            end
          end
        end
      end

      # JSON-RPC formatted 429 for MCP requests; the general Otto response
      # (route response_type, then Accept header) for everything else.
      def self.throttled_response(request)
        return super unless mcp_request?(request)

        match_data = request.env['rack.attack.match_data']
        headers    = throttle_headers(match_data)

        error_response = {
          jsonrpc: '2.0',
          id: nil,
          error: {
            code: -32_000,
            message: 'Rate limit exceeded',
            data: {
              retry_after: headers['retry-after'].to_i,
              limit: match_data[:limit],
              period: match_data[:period],
            },
          },
        }
        [429, headers, [JSON.generate(error_response)]]
      end

      # Keep one MCP-aware subscriber while allowing it to recognize every
      # endpoint registered in this process.
      def self.configure_logging
        return unless defined?(ActiveSupport::Notifications)

        ActiveSupport::Notifications.unsubscribe(@log_subscriber) if @log_subscriber
        @log_subscriber = ActiveSupport::Notifications.subscribe('rack.attack') do |_name, _start, _finish, _request_id, payload|
          log_throttled_request(payload)
        end
      end

      # Masked address only — see the note on the base implementation in
      # Otto::Security::RateLimiting (issue #219).
      def self.log_throttled_request(payload)
        req = payload[:request]
        return super unless mcp_request?(req)

        ip = Otto::LoggingHelpers.privacy_safe_ip(req.env, req.ip)
        Otto.logger.warn "[MCP] Rate limit #{payload[:match_type]} for #{ip}: #{payload[:matched]}"
      end
    end

    # Middleware for applying rate limits to MCP protocol endpoints
    class RateLimitMiddleware < Otto::Security::RateLimitMiddleware
      def initialize(app, security_config = nil)
        @app             = app
        @security_config = security_config

        configure_mcp_rate_limiting
      end

      private

      def configure_mcp_rate_limiting
        # Get base configuration from security config
        base_config = @security_config&.rate_limiting_config || {}

        # MCP defaults, overridden by anything the security config carries
        # (Server#apply_rate_limits publishes the configured limits and the
        # endpoint there).
        mcp_config = {
          mcp_requests_per_minute: 60,
          tool_calls_per_minute: 20,
        }.merge(base_config)

        RateLimiter.configure_rack_attack!(mcp_config)
      end
    end
  end
end
