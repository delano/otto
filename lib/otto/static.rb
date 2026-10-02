# lib/otto/static.rb
#
# frozen_string_literal: true

require 'rack/utils'

class Otto
  # Static response utilities for common HTTP responses
  module Static
    extend self

    def server_error(security_config = nil)
      [500, security_headers(security_config).merge({ 'content-type' => 'text/plain' }), ['Server error']]
    end

    def not_found(security_config = nil)
      [404, security_headers(security_config).merge({ 'content-type' => 'text/plain' }), ['Not Found']]
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

    # Replace the body of a response to a HEAD request with an empty one.
    #
    # Rack::Lint rejects a body for HEAD: "Response body was given for HEAD
    # request, but should be empty" (rack/lint.rb). The status and headers,
    # including any content-length the handler set, are kept.
    #
    # Puma and Rack::ContentLength derive content-length from an Array body
    # through #to_ary, so an empty Array would advertise 0 for HEAD while GET
    # advertises the real length, which RFC 9110 section 8.6 forbids. When the
    # handler's body is a plain Array and the response has no content-length
    # or transfer-encoding and a status that allows content, content-length is
    # set from the Array here instead (a plain Array has no #close, so reading
    # it has no side effect). The returned body has no #to_ary, so nothing
    # downstream computes a length from it or closes it early; the handler's
    # body is closed when the server closes the returned body, the same point
    # at which a GET body is closed. A new triple is returned rather than
    # writing into +response+, which may be frozen or shared.
    #
    # @param response [Array] a Rack triple +[status, headers, body]+
    # @return [Array] +[status, headers, HeadBody]+
    def head_response(response)
      status, headers, body = response
      if array_length_applies?(status, headers, body)
        headers = copy_headers(headers)
        headers['content-length'] = body.sum { |part| part.to_s.bytesize }.to_s
      end
      [status, headers, HeadBody.new(body)]
    end

    # Headers whose presence means #head_response leaves content-length alone.
    HEAD_LENGTH_HEADERS = %w[content-length transfer-encoding].freeze

    # Whether #head_response should set content-length from an Array body.
    def array_length_applies?(status, headers, body)
      return false unless body.is_a?(Array) && headers
      return false if Rack::Utils::STATUS_WITH_NO_ENTITY_BODY.key?(status.to_i)

      headers.each_key.none? { |key| HEAD_LENGTH_HEADERS.include?(key.to_s.downcase) }
    end
    private :array_length_applies?

    # Empty body for a HEAD response. It yields nothing and has no #to_ary.
    # Closing it closes the handler's body once.
    class HeadBody
      def initialize(original)
        @original = original
        @closed   = false
      end

      def each; end

      def close
        return if @closed

        @closed = true
        @original.close if @original.respond_to?(:close)
      end

      def closed? = @closed
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

    def security_headers(security_config = nil)
      {
        'x-frame-options' => 'DENY',
        'x-content-type-options' => 'nosniff',
        'x-xss-protection' => '1; mode=block',
        'referrer-policy' => security_config&.referrer_policy ||
          Otto::Security::Config::DEFAULT_REFERRER_POLICY,
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
