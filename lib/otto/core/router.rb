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
          next if parts.size < 3 # Skip malformed entries

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

          route                                   = Otto::Route.new verb, path, definition
          route.otto                              = self
          path_clean                              = path.gsub(%r{/$}, '')
          @route_definitions[route.definition]    = route
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
        @static_route    ||= Rack::Files.new(option[:public]) if option[:public] && safe_dir?(option[:public])
        path_info          = Rack::Utils.unescape(env['PATH_INFO'])
        path_info          = '/' if path_info.to_s.empty?

        begin
          path_info_clean = path_info
                            .encode(
                              'UTF-8', # Target encoding
                              invalid: :replace, # Replace invalid byte sequences
                              undef: :replace,   # Replace characters undefined in UTF-8
                              replace: '' # Use empty string for replacement
                            )
                            .gsub(%r{/$}, '') # Remove trailing slash, if present
        rescue ArgumentError => e
          # Log the error but don't expose details
          Otto.logger.error '[Otto.handle_request] Path encoding error'
          Otto.logger.debug "[Otto.handle_request] Error details: #{e.message}" if Otto.debug
          # Set a default value or use the original path_info
          path_info_clean = path_info
        end

        base_path      = File.split(path_info).first
        # Files in the root directory can refer to themselves
        base_path      = path_info if base_path == '/'
        http_verb      = env['REQUEST_METHOD'].upcase.to_sym
        literal_routes = routes_literal[http_verb] || {}
        literal_routes.merge! routes_literal[:GET] if http_verb == :HEAD

        if static_route && http_verb == :GET && routes_static[:GET].member?(base_path)
          Otto.structured_log(:debug, 'Route matched',
            Otto::LoggingHelpers.request_context(env).merge(
              type: 'static_cached',
              base_path: base_path
            ))
          static_route.call(env)
        elsif literal_routes.has_key?(path_info_clean)
          route = literal_routes[path_info_clean]
          Otto.structured_log(:debug, 'Route matched',
            Otto::LoggingHelpers.request_context(env).merge(
              type: 'literal',
              handler: route.route_definition.definition,
              auth_strategy: route.route_definition.auth_requirement || 'none'
            ))
          route.call(env)
        elsif static_route && http_verb == :GET && safe_file?(path_info)
          Otto.structured_log(:debug, 'Route matched',
            Otto::LoggingHelpers.request_context(env).merge(
              type: 'static_new',
              base_path: base_path
            ))
          routes_static[:GET][base_path] = base_path
          static_route.call(env)
        else
          match_dynamic_route(env, path_info, http_verb, literal_routes)
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

      def match_dynamic_route(env, path_info, http_verb, literal_routes)
        extra_params  = {}
        found_route   = nil
        valid_routes  = routes[http_verb] || []
        valid_routes.push(*routes[:GET]) if http_verb == :HEAD

        valid_routes.each do |route|
          next unless (match = route.pattern.match(path_info))

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
      rescue StandardError => e
        Otto.logger.error "[MCP] Failed to parse MCP route: #{definition} - #{e.message}"
      end

      def handle_tool_route(verb, path, definition)
        raise '[MCP] MCP server not enabled' unless @mcp_server

        route_info = Otto::MCP::RouteParser.parse_tool_route(verb, path, definition)
        @mcp_server.register_mcp_route(route_info)
        Otto.logger.debug "[MCP] Registered tool route: #{definition}" if Otto.debug
      rescue StandardError => e
        Otto.logger.error "[MCP] Failed to parse TOOL route: #{definition} - #{e.message}"
      end
    end
  end
end
