# lib/otto/security/authentication/strategies/session_strategy.rb

require_relative '../auth_strategy'

class Otto
  module Security
    module Authentication
      module Strategies
        # Session-based authentication strategy
        class SessionStrategy < AuthStrategy
          def initialize(session_key: 'user_id', session_store: nil)
            @session_key = session_key
            @session_store = session_store
          end

          def authenticate(env, _requirement)
            session = env['rack.session']
            return failure('No session available') unless session

            user_id = session[@session_key]
            return failure('Not authenticated') unless user_id

            # Create a simple user hash for the generic strategy
            user_data = { id: user_id, user_id: user_id }
            success(session: session, user: user_data, auth_method: 'session')
          end

          def user_context(env)
            session = env['rack.session']
            return {} unless session

            user_id = session[@session_key]
            return {} unless user_id

            { user_id: user_id }
          end
        end
      end
    end
  end
end
