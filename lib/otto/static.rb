# lib/otto/static.rb
#
# frozen_string_literal: true

class Otto
  # Static response utilities for common HTTP responses
  module Static
    extend self

    def server_error
      [500, security_headers.merge({ 'content-type' => 'text/plain' }), ['Server error']]
    end

    def not_found
      [404, security_headers.merge({ 'content-type' => 'text/plain' }), ['Not Found']]
    end

    # Return a per-request copy of a Rack triple so callers can never hand a
    # shared object back to the Rack stack.
    #
    # Middleware above Otto (rack-session, Otto's own CSRF middleware, anything
    # that calls +Rack::Utils.set_cookie_header!+) writes response headers in
    # place. Returning a configured triple by reference lets those writes
    # accumulate on the shared object for the life of the process, so every
    # subsequent 404/500 replays every Set-Cookie any earlier one committed.
    #
    # The copy is intentionally shallow-plus-one: the headers container keeps
    # its class (a +Rack::Headers+ stays case-insensitive), each Array-valued
    # header (Rack 3's representation of a repeated header) is copied so an
    # append cannot reach the shared Array, and an Array body is copied so a
    # middleware appending chunks cannot grow the shared body. A frozen
    # configured triple yields an unfrozen copy, so cookie middleware works
    # after configuration freezing as well.
    #
    # @param response [Array] a Rack triple +[status, headers, body]+
    # @return [Array] a new triple that shares no mutable container with +response+
    def copy_response(response)
      status, headers, body = response
      [status, copy_headers(headers), body.is_a?(Array) ? body.dup : body]
    end

    # Copy a Rack headers container, keeping its class and copying Array values.
    #
    # @param headers [Hash, Rack::Headers, nil] the headers to copy
    # @return [Hash, Rack::Headers] a new container of the same class
    def copy_headers(headers)
      return {} if headers.nil?

      copied = headers.dup
      copied.each_pair do |key, value|
        copied[key] = value.dup if value.is_a?(Array)
      end
      copied
    end

    def security_headers
      {
        'x-frame-options' => 'DENY',
        'x-content-type-options' => 'nosniff',
        'x-xss-protection' => '1; mode=block',
        'referrer-policy' => 'strict-origin-when-cross-origin',
      }
    end

    # Enable string or symbol key access to the nested params hash.
    def indifferent_params(params)
      if params.is_a?(Hash)
        params = indifferent_hash.merge(params)
        params.each do |key, value|
          next unless value.is_a?(Hash) || value.is_a?(Array)

          params[key] = indifferent_params(value)
        end
      elsif params.is_a?(Array)
        params.collect! do |value|
          if value.is_a?(Hash) || value.is_a?(Array)
            indifferent_params(value)
          else
            value
          end
        end
      end
    end

    # Creates a Hash with indifferent access.
    def indifferent_hash
      Hash.new { |hash, key| hash[key.to_s] if key.is_a?(Symbol) }
    end
  end
end
