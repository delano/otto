# lib/otto/security/authentication/strategies/api_key_strategy.rb
#
# frozen_string_literal: true

require_relative '../auth_strategy'
require 'digest'
require 'rack/utils'

class Otto
  module Security
    module Authentication
      module Strategies
        # API key authentication strategy.
        #
        # Fails closed: at least one non-empty API key MUST be configured. A
        # strategy with no usable keys is a misconfiguration and raises
        # ArgumentError at construction rather than authenticating every caller.
        # Only a constant-time match against a configured key grants success.
        #
        # A credential that was presented and rejected — including a non-String
        # credential such as an array query parameter — fails TERMINALLY, so a bad
        # key halts the strategy chain instead of falling through to a later
        # anonymous-capable strategy. A missing credential fails non-terminally.
        #
        # The result never carries the raw key: it exposes only a short SHA-256
        # fingerprint, so the secret does not reach env, session, or logs.
        #
        # The query/form parameter path is opt-in (`param_name:`), because keys in
        # URLs are recorded by access logs, proxies, and browser history.
        #
        # @example Header only (recommended)
        #   APIKeyStrategy.new(api_keys: ['secret123'])
        # @example Also accept ?api_key= (logged in URLs; prefer the header)
        #   APIKeyStrategy.new(api_keys: ['secret123'], param_name: 'api_key')
        class APIKeyStrategy < AuthStrategy
          # @param api_keys [String, Array<String>] one or more valid API keys (required)
          # @param header_name [String] request header carrying the key
          # @param param_name [String, nil] query/form parameter carrying the key.
          #   Defaults to nil (header only): keys placed in a URL are captured by
          #   access logs, proxies, and browser history. Pass 'api_key' to opt in.
          # @raise [ArgumentError] if no non-empty API key is configured
          def initialize(api_keys:, header_name: 'X-API-Key', param_name: nil)
            super()
            @api_keys = Array(api_keys).map(&:to_s).reject(&:empty?).freeze
            if @api_keys.empty?
              raise ArgumentError,
                    'APIKeyStrategy requires at least one non-empty API key ' \
                    '(api_keys: was empty, nil, or contained only blank values)'
            end

            @header_name = header_name
            @param_name = param_name
          end

          def authenticate(env, _requirement)
            # Header first; the parameter path is consulted only when opted in.
            api_key = env["HTTP_#{@header_name.upcase.tr('-', '_')}"]

            if api_key.nil? && @param_name
              request = Otto::Request.new(env)
              api_key = request.params[@param_name]
            end

            # '' is truthy in Ruby; treat it as a missing credential.
            return failure('No API key provided') if api_key.nil? || (api_key.is_a?(String) && api_key.empty?)

            # A non-String credential (e.g. `?api_key[]=k` yields an Array) was
            # still presented, so reject it terminally rather than coercing it
            # into a comparison Rack::Utils.secure_compare cannot perform.
            unless api_key.is_a?(String) && valid_api_key?(api_key)
              # Credentials were explicitly presented and rejected: fail closed.
              return failure('Invalid API key', terminal: true)
            end

            # Identify the credential by a non-reversible fingerprint. The raw key
            # must not reach the result, since it flows into env, session, and logs.
            fingerprint = key_fingerprint(api_key)
            success(user: { api_key_fingerprint: fingerprint },
                    auth_method: 'api_key',
                    api_key_fingerprint: fingerprint)
          end

          private

          # Short, non-reversible identifier for a key: enough to correlate
          # requests and audit logs without exposing the credential.
          def key_fingerprint(api_key)
            Digest::SHA256.hexdigest(api_key)[0, 12]
          end

          # Constant-time membership check over the configured API keys. Compares
          # against every key without short-circuiting so match position/membership is
          # not leaked via timing.
          def valid_api_key?(api_key)
            @api_keys.reduce(false) do |matched, key|
              Rack::Utils.secure_compare(key, api_key) || matched
            end
          end
        end
      end
    end
  end
end
