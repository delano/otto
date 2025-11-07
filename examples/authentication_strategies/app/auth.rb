# examples/authentication_strategies/app/auth.rb

# Authentication result data class to contain the session, user and anything
# else we want to make available to the route handlers/controllers/logic classes.
AuthResultData = Data.define(:session, :user) do
  def initialize(session: {}, user: {})
    super(session: session, user: user)
  end

  # Provide user_context method for compatibility with existing AuthResult
  def user_context
    { session: session, user: user }
  end
end

module AuthenticationSetup
  def self.configure(otto)
    # Simple auth strategy that checks for a token parameter or header
    otto.add_auth_strategy('authenticated', lambda do |req|
      token = req.params['token'] || req.get_header('HTTP_AUTHORIZATION')
      if token == 'demo_token'
        AuthResultData.new(
          session: { session_id: 'demo_session_123', user_id: 1 },
          user: { name: 'Demo User', role: 'user', permissions: %w[read write] }
        )
      end
    end)

    # Role-based auth strategy
    otto.add_auth_strategy('role:admin', lambda do |req|
      token = req.params['token'] || req.get_header('HTTP_AUTHORIZATION')
      if token == 'admin_token'
        AuthResultData.new(
          session: { session_id: 'admin_session_456', user_id: 2 },
          user: { name: 'Admin User', role: 'admin', permissions: %w[read write admin delete] }
        )
      end
    end)

    # Permission-based auth strategy
    otto.add_auth_strategy('permission:write', lambda do |req|
      token = req.params['token'] || req.get_header('HTTP_AUTHORIZATION')
      case token
      when 'demo_token'
        AuthResultData.new(
          session: { session_id: 'demo_session_123', user_id: 1 },
          user: { name: 'Demo User', role: 'user', permissions: %w[read write] }
        )
      when 'admin_token'
        AuthResultData.new(
          session: { session_id: 'admin_session_456', user_id: 2 },
          user: { name: 'Admin User', role: 'admin', permissions: %w[read write admin delete] }
        )
      end
    end)

    # API key auth strategy
    otto.add_auth_strategy('api_key', lambda do |req|
      api_key = req.params['api_key'] || req.get_header('HTTP_X_API_KEY')
      if api_key == 'demo_api_key_123'
        AuthResultData.new(
          session: { api_session: 'api_session_abc' },
          user: { name: 'API Client', type: 'api', permissions: ['api_access'] }
        )
      end
    end)
  end
end
