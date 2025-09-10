# frozen_string_literal: true
# lib/otto/core/uri_generator.rb

require 'uri'

class Otto
  module Core
    module UriGenerator
      # Return the URI path for the given +route_definition+
      # e.g.
      #
      #     Otto.default.path 'YourClass.somemethod'  #=> /some/path
      #
      def uri(route_definition, params = {})
        # raise RuntimeError, "Not working"
        route = @route_definitions[route_definition]
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
    end
  end
end
