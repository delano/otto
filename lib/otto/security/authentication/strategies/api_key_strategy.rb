# lib/otto/security/authentication/strategies/api_key_strategy.rb
#
# frozen_string_literal: true

require_relative '../auth_strategy'
require 'rack/utils'

class Otto
  module Security
    module Authentication
      module Strategies
        # API key authentication strategy
        class APIKeyStrategy < AuthStrategy
          def initialize(api_keys: [], header_name: 'X-API-Key', param_name: 'api_key')
            @api_keys = Array(api_keys)
            @header_name = header_name
            @param_name = param_name
          end

          def authenticate(env, _requirement)
            # Try header first, then query parameter
            api_key = env["HTTP_#{@header_name.upcase.tr('-', '_')}"]

            if api_key.nil?
              request = Otto::Request.new(env)
              api_key = request.params[@param_name]
            end

            return failure('No API key provided') unless api_key

            if @api_keys.empty? || valid_api_key?(api_key)
              # Create a simple user hash for API key authentication
              user_data = { api_key: api_key }
              success(user: user_data, api_key: api_key)
            else
              failure('Invalid API key')
            end
          end

          private

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
