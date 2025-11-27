# frozen_string_literal: true

class Otto
  module Security
    module Authentication
      module RouteAuthWrapperComponents
        # Resolves authentication strategy names to strategy instances
        #
        # Handles strategy lookup with caching and pattern matching:
        # - Exact match: 'authenticated' → looks up auth_config[:auth_strategies]['authenticated']
        # - Prefix match: 'custom:value' → looks up 'custom' strategy
        #
        # Results are cached to avoid repeated lookups for the same requirement.
        #
        # @example
        #   resolver = StrategyResolver.new(auth_config)
        #   strategy, name = resolver.resolve('session')
        #   strategy, name = resolver.resolve('oauth:google')  # prefix match
        #
        class StrategyResolver
          # @param auth_config [Hash] Auth configuration with :auth_strategies key
          def initialize(auth_config)
            @auth_config = auth_config
            @cache = {}
          end

          # Resolve a requirement string to a strategy instance
          #
          # @param requirement [String] Auth requirement from route (e.g., 'session', 'oauth:google')
          # @return [Array<AuthStrategy, String>, Array<nil, nil>] Tuple of [strategy, name] or [nil, nil]
          def resolve(requirement)
            return [nil, nil] unless @auth_config && @auth_config[:auth_strategies]

            # Check cache first
            return @cache[requirement] if @cache.key?(requirement)

            result = find_strategy(requirement)
            @cache[requirement] = result
            result
          end

          # Clear the strategy cache
          def clear_cache
            @cache.clear
          end

          private

          def find_strategy(requirement)
            strategies = @auth_config[:auth_strategies]

            # Try exact match first - highest priority
            strategy = strategies[requirement]
            return [strategy, requirement] if strategy

            # For colon-separated requirements like "custom:value", try prefix match
            if requirement.include?(':')
              prefix = requirement.split(':', 2).first
              prefix_strategy = strategies[prefix]
              return [prefix_strategy, prefix] if prefix_strategy
            end

            [nil, nil]
          end
        end
      end
    end
  end
end
