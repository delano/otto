# lib/otto/security/authentication/strategies/noauth_strategy.rb
#
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
            # Canonical client IP ("resolve once, read everywhere"): masked by
            # IPPrivacyMiddleware when privacy is on; REMOTE_ADDR fallback when
            # the middleware has not run.
            metadata = { ip: env['otto.client_ip'] || env['REMOTE_ADDR'] }
            metadata[:country] = env['otto.privacy.geo_country'] if env['otto.privacy.geo_country']

            Otto::Security::Authentication::StrategyResult.anonymous(metadata: metadata)
          end
        end
      end
    end
  end
end
