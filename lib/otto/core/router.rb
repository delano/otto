# lib/otto/core/router.rb
#
# frozen_string_literal: true

require_relative '../mcp/route_parser'

class Otto
  module Core
    # Router module providing route loading and request dispatching functionality
    module Router
      def load(path)
        path = File.expand_path(path)
        raise ArgumentError, "Bad path: #{path}" unless File.exist?(path)

        raw = File.readlines(path).grep(/^\w/).collect(&:strip)
        raw.each do |entry|
          # Enhanced parsing: split only on first two whitespace boundaries
          # This preserves parameters in the definition part
          parts = entry.split(/\s+/, 3)
          if parts.size < 3
            # A missing/blank handler must not make the route vanish silently
            # (issue #191): warn unconditionally, not gated behind Otto.debug.
            Otto.structured_log(:warn, 'Malformed route line skipped',
              { line: entry, expected: 'VERB /path Handler [options]' })
            next
          end

          verb = parts[0]
          path = parts[1]
          definition = parts[2]

          # Check for MCP routes
          if Otto::MCP::RouteParser.is_mcp_route?(definition)
            handle_mcp_route(verb, path, definition)
            next
          elsif Otto::MCP::RouteParser.is_tool_route?(definition)
            handle_tool_route(verb, path, definition)
            next
          end

          route      = Otto::Route.new verb, path, definition
          route.otto = self
          path_clean = path.gsub(%r{/$}, '')

          # A definition string is not unique (the same handler can be mounted
          # at several verb/path pairs), so @route_definitions keeps the
          # first-loaded route per definition — deterministic, instead of the
          # last-loaded route silently winning — and @routes_by_definition
          # keeps them all for uri() disambiguation (issue #190).
          if (existing = @route_definitions[route.definition])
            # Mounting one handler at several paths is a fully supported
            # pattern (issue #190) — uri() disambiguates by params, so this
            # is informational, not a problem. Debug-gated like other
            # routing diagnostics rather than warning on every boot for
            # valid configs (e.g. `/users/:id` and `/me` aliases).
            Otto.structured_log(:debug, 'Duplicate route definition',
              {
                definition: route.definition,
                kept: "#{existing.verb} #{existing.path}",
                also: "#{route.verb} #{route.path}",
                hint: 'uri() picks the route whose path params match the given params',
              })
          else
            @route_definitions[route.definition] = route
          end
          (@routes_by_definition[route.definition] ||= []) << route
          if Otto.debug
            Otto.structured_log(:debug, 'Route loaded',
              {
                   pattern: route.pattern.source,
                verb: route.verb,
                definition: route.definition,
                type: 'pattern',
              })
          end
          @routes[route.verb] ||= []
          @routes[route.verb] << route
          @routes_literal[route.verb]           ||= {}
          @routes_literal[route.verb][path_clean] = route
        rescue Otto::RouteDefinitionError
          # A malformed security-gating option (auth/role/csrf) fails fast at
          # boot rather than serving the route without its intended protection
          # (issue #191). Deliberately not swallowed like other per-line errors.
          raise
        rescue StandardError => e
          Otto.structured_log(:error, 'Route load failed',
            {
                     path: path,
              verb: verb,
              definition: definition,
              error: e.message,
              error_class: e.class.name,
            })
          Otto.logger.debug e.backtrace.join("\n") if Otto.debug
        end
        self
      end

      def handle_request(env)
        locale             = determine_locale env
        env['rack.locale'] = locale
        env['otto.locale_config'] = @locale_config.to_h if @locale_config
        # Rack::Files is rooted at the CANONICAL public directory, so the
        # symlink-free relative path #serve_static_file hands it is joined to a
        # symlink-free root (issue #257). A missing root leaves @static_route
        # nil and the request falls through to normal routing (404), rather
        # than raising at construction.
        @static_route    ||= build_static_route
        path_info          = Rack::Utils.unescape(env['PATH_INFO'])
        path_info          = '/' if path_info.to_s.empty?

        begin
          # Shared with Otto::CaddyTLS::LocalhostGuard so the guard and the
          # router cannot normalize a path differently (which would be a guard
          # bypass). See Otto::Utils.normalize_path.
          path_info_clean = Otto::Utils.normalize_path(env['PATH_INFO'])
        rescue ArgumentError => e
          # Log the error but don't expose details
          Otto.logger.error '[Otto.handle_request] Path encoding error'
          Otto.logger.debug "[Otto.handle_request] Error details: #{e.message}" if Otto.debug
          # Set a default value or use the original path_info
          path_info_clean = path_info
        end

        http_verb      = env['REQUEST_METHOD'].upcase.to_sym
        literal_routes = routes_literal[http_verb] || {}
        literal_routes.merge! routes_literal[:GET] if http_verb == :HEAD

        # Dynamic-route and static-file dispatch match against the SAME
        # normalized path the literal table and the LocalhostGuard use, so all
        # dispatch paths share one normalization (issue #187). Without this,
        # dynamic routes matched the raw (unescape-only) path: they were
        # stricter about trailing slashes than literal routes (equivalent URLs
        # matched or missed depending on route kind), and invalid-UTF-8 bytes
        # scrubbed for the guard and literal matching survived into the dynamic
        # matcher and safe_file? — the guard-bypass class normalize_path exists
        # to close. normalize_path collapses root to '' after stripping the
        # trailing slash; the regex matcher and safe_file? need a leading slash
        # to be structural (a catch-all `/*` still matches `/`), so restore '/'
        # for them. Literal lookup keeps '' — it already keys root that way.
        dispatch_path = path_info_clean.empty? ? '/' : path_info_clean

        # Static dispatch is gated on the SAME containment check every time,
        # including cache hits (issue #257). routes_static caches the base
        # path (the *directory* of an approved file), so a cache hit alone
        # authorized every sibling of an already-served file -- a symlink
        # dropped next to it escaped the public root. The cache now only
        # decides ordering versus literal routes, never safety.
        static_candidate = !static_route.nil? && http_verb == :GET
        # The cache is keyed on the CANONICAL directory of an approved file
        # (see #static_cache_key), not on File.split of the request path: the
        # latter preserved '.' segments, so '/a/./././x.txt' variants minted
        # unbounded distinct keys in the Concurrent::Map. Lookups use the
        # lexical dirname; odd paths simply miss and take the cold branch.
        lookup_key       = File.dirname(dispatch_path)
        static_file      = if static_candidate && routes_static[:GET].key?(lookup_key)
                             resolve_static_file(dispatch_path)
                           end

        if static_file
          Otto.structured_log(:debug, 'Route matched',
            Otto::LoggingHelpers.request_context(env).merge(
              type: 'static_cached',
              base_path: lookup_key
            ))
          serve_static_file(env, static_file)
        elsif literal_routes.has_key?(path_info_clean)
          route = literal_routes[path_info_clean]
          Otto.structured_log(:debug, 'Route matched',
            Otto::LoggingHelpers.request_context(env).merge(
              type: 'literal',
              handler: route.route_definition.definition,
              auth_strategy: route.route_definition.auth_requirement || 'none'
            ))
          # Fire route matched hooks before dispatch; raises propagate to handle_error
          unless @route_matched_callbacks.empty?
            @route_matched_callbacks.each { |cb| cb.call(env, route.route_definition) }
          end
          route.call(env)
        elsif static_candidate && (static_file = resolve_static_file(dispatch_path))
          cache_key = static_cache_key(static_file)
          Otto.structured_log(:debug, 'Route matched',
            Otto::LoggingHelpers.request_context(env).merge(
              type: 'static_new',
              base_path: cache_key
            ))
          routes_static[:GET][cache_key] = cache_key
          serve_static_file(env, static_file)
        else
          match_dynamic_route(env, dispatch_path, http_verb, literal_routes)
        end
      end

      def determine_locale(env)
        accept_langs = env['HTTP_ACCEPT_LANGUAGE']
        accept_langs = option[:locale] if accept_langs.to_s.empty?
        locales      = []
        unless accept_langs.empty?
          locales = accept_langs.split(',').map do |l|
            l += ';q=1.0' unless /;q=\d+(?:\.\d+)?$/.match?(l)
            l.split(';q=')
          end.sort_by do |_locale, qvalue|
            qvalue.to_f
          end.collect do |locale, _qvalue|
            locale
          end.reverse
        end
        Otto.logger.debug "locale: #{locales} (#{accept_langs})" if Otto.debug
        locales.empty? ? nil : locales
      end

      private

      # Serve the path that was actually validated, not the request path.
      #
      # Rack::Files re-derives its target by joining its root with PATH_INFO,
      # so handing it the raw request path reopened the check/open gap that
      # #resolve_static_file just closed: an approved request path could be
      # re-resolved through a symlink at open time. Rewriting PATH_INFO to the
      # canonical (fully symlink-resolved) relative path means the path
      # Rack::Files opens contains no symlink components at all.
      #
      # Residual TOCTOU: a real (non-symlink) component renamed between the
      # File.realpath in #resolve_static_file and the File.open inside
      # Rack::Files could still redirect the open. Closing that requires an
      # O_NOFOLLOW-per-component or fd-based serve, i.e. replacing
      # Rack::Files. Accepted for now; see issue #257.
      def serve_static_file(env, static_file)
        static_env = env.dup
        # Rack::Files unescapes PATH_INFO, so escape the canonical path to
        # survive the round trip (escape_path preserves '/').
        static_env['PATH_INFO'] = "/#{Rack::Utils.escape_path(static_file.relative)}"
        static_route_for(static_file.root).call(static_env)
      end

      # Rack::Files rooted at the root +static_file+ was validated against.
      #
      # @static_route is memoised once, but the public directory can be
      # repointed without a restart (a release symlink flip). Containment
      # re-resolves the root on every request and would validate against the
      # new tree while the memoised Rack::Files kept opening files under the
      # old one, so a validated relative path could be joined to a root it was
      # never checked against. Rebuild whenever the two diverge. The race
      # between two threads rebuilding at once is benign: both produce an
      # equivalent instance for the same root.
      def static_route_for(root)
        current = static_route
        return current if current && current.root == root

        @static_route = Rack::Files.new(root)
      end

      def build_static_route
        return nil if option[:public].nil? || option[:public].empty?
        return nil unless safe_dir?(option[:public])

        root = canonical_public_dir
        root && Rack::Files.new(root)
      end

      # +dispatch_path+ is the normalized path from #handle_request (see the
      # +dispatch_path+ comment there): +Otto::Utils.normalize_path+ output with
      # root's empty string mapped back to '/' so the anchored route regexes can
      # match. It is deliberately NOT the raw +normalize_path+ value.
      def match_dynamic_route(env, dispatch_path, http_verb, literal_routes)
        extra_params  = {}
        found_route   = nil
        valid_routes  = routes[http_verb] || []
        valid_routes.push(*routes[:GET]) if http_verb == :HEAD

        valid_routes.each do |route|
          next unless (match = route.pattern.match(dispatch_path))

          values = match.captures.to_a
          # The first capture returned is the entire matched string b/c
          # we wrapped the entire regex in parens. We don't need it to
          # the full match.
          values.shift
          extra_params = build_route_params(route, values)
          found_route  = route

          # Log successful route match
          Otto.structured_log(:debug, 'Route matched',
            Otto::LoggingHelpers.request_context(env).merge(
              pattern: route.pattern.source,
              handler: route.route_definition.definition,
              auth_strategy: route.route_definition.auth_requirement || 'none',
              route_params: extra_params
            ))
          break
        end

        found_route ||= literal_routes['/404']
        if found_route
          # Log 404 route usage if we fell back to it
          if found_route == literal_routes['/404']
            Otto.structured_log(:info, 'Route not found',
              Otto::LoggingHelpers.request_context(env).merge(
                fallback_to: '404_route'
              ))
          else
            # Fire route matched hooks before dispatch; suppressed for 404 fallback.
            # Raises propagate to handle_error so custom error classes can be registered.
            unless @route_matched_callbacks.empty?
              @route_matched_callbacks.each { |cb| cb.call(env, found_route.route_definition) }
            end
          end
          found_route.call env, extra_params
        else
          Otto.structured_log(:info, 'Route not found',
            Otto::LoggingHelpers.request_context(env).merge(
              fallback_to: 'default_not_found'
            ))
          @not_found || Otto::Static.not_found
        end
      end

      def build_route_params(route, values)
        if route.keys.any?
          route.keys.zip(values).each_with_object({}) do |(k, v), hash|
            if k == 'splat'
              (hash[k] ||= []) << v
            else
              hash[k] = v
            end
          end
        elsif values.any?
          { 'captures' => values }
        else
          {}
        end
      end

      def handle_mcp_route(verb, path, definition)
        raise '[MCP] MCP server not enabled' unless @mcp_server

        route_info = Otto::MCP::RouteParser.parse_mcp_route(verb, path, definition)
        @mcp_server.register_mcp_route(route_info)
        Otto.logger.debug "[MCP] Registered resource route: #{definition}" if Otto.debug
      rescue Otto::RouteDefinitionError
        # Same fail-fast contract as the normal route loader: a malformed
        # security-gating option must abort boot, not just log-and-drop.
        raise
      rescue StandardError => e
        Otto.logger.error "[MCP] Failed to parse MCP route: #{definition} - #{e.message}"
      end

      def handle_tool_route(verb, path, definition)
        raise '[MCP] MCP server not enabled' unless @mcp_server

        route_info = Otto::MCP::RouteParser.parse_tool_route(verb, path, definition)
        @mcp_server.register_mcp_route(route_info)
        Otto.logger.debug "[MCP] Registered tool route: #{definition}" if Otto.debug
      rescue Otto::RouteDefinitionError
        raise
      rescue StandardError => e
        Otto.logger.error "[MCP] Failed to parse TOOL route: #{definition} - #{e.message}"
      end
    end
  end
end
