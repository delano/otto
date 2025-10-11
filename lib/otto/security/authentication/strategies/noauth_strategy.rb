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
            Otto::Security::Authentication::StrategyResult.anonymous(metadata: { ip: env['REMOTE_ADDR'] })
          end
        end
      end
    end
  end
end
