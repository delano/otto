# lib/otto/core/uri_generator.rb
#
# frozen_string_literal: true

require 'uri'

class Otto
  module Core
    # URI generation module providing path and URL generation for route definitions
    module UriGenerator
      # Return the URI path for the given +route_definition+
      # e.g.
      #
      #     Otto.default.path 'YourClass.somemethod'  #=> /some/path
      #
      def uri(route_definition, params = {})
        route = select_uri_route(route_definition, params)
        return if route.nil?

        local_params = params.clone
        local_path   = route.path.clone

        keys_to_remove = []
        local_params.each_pair do |k, v|
          next unless local_path.match(":#{k}")

          local_path.gsub!(":#{k}", v.to_s)
          keys_to_remove << k
        end
        keys_to_remove.each { |k| local_params.delete(k) }

        uri = URI::HTTP.new(nil, nil, nil, nil, nil, local_path, nil, nil, nil)
        unless local_params.empty?
          query_string = local_params.map do |k, v|
            "#{URI.encode_www_form_component(k)}=#{URI.encode_www_form_component(v)}"
          end.join('&')
          uri.query = query_string
        end
        uri.to_s
      end

      private

      # Pick which route a reverse lookup means when one definition string is
      # mounted at several verb/path pairs (issue #190). Routes whose path
      # placeholders are all present in +params+ are preferred; among those,
      # the route consuming the most params wins. Ties keep load order, so a
      # single-route definition behaves exactly as before.
      #
      # e.g. with `GET /users/:id Account#show` and `GET /me Account#show`:
      #   uri('Account#show', id: 5) #=> /users/5
      #   uri('Account#show')        #=> /me
      def select_uri_route(route_definition, params)
        candidates = routes_for_definition(route_definition)
        # @route_definitions fallback covers hand-assembled instances whose
        # routes never went through Otto#load.
        return candidates.first || @route_definitions[route_definition] if candidates.size <= 1

        param_keys = params.keys.map(&:to_s)
        satisfied  = candidates.select { |route| (route.keys - param_keys).empty? }
        pool       = satisfied.empty? ? candidates : satisfied
        pool.max_by { |route| (route.keys & param_keys).size }
      end

      def routes_for_definition(route_definition)
        (@routes_by_definition && @routes_by_definition[route_definition]) || []
      end
    end
  end
end
