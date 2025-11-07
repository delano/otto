# lib/otto/security/authentication/strategies/api_key_strategy.rb

require_relative '../auth_strategy'

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
              request = Rack::Request.new(env)
              api_key = request.params[@param_name]
            end

            return failure('No API key provided') unless api_key

            if @api_keys.empty? || @api_keys.include?(api_key)
              # Create a simple user hash for API key authentication
              user_data = { api_key: api_key }
              success(user: user_data, api_key: api_key)
            else
              failure('Invalid API key')
            end
          end
        end
      end
    end
  end
end
