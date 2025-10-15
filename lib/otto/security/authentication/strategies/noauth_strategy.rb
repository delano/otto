# frozen_string_literal: true

require_relative '../auth_strategy'
require_relative '../strategy_result'

class Otto
  module Security
    module Authentication
      module Strategies
        # Public access strategy - always allows access
        class NoAuthStrategy < AuthStrategy
          def authenticate(env, _requirement)
            # Note: env['REMOTE_ADDR'] is masked by IPPrivacyMiddleware by default
            metadata = { ip: env['REMOTE_ADDR'] }
            metadata[:country] = env['otto.geo_country'] if env['otto.geo_country']

            Otto::Security::Authentication::StrategyResult.anonymous(metadata: metadata)
          end
        end
      end
    end
  end
end
