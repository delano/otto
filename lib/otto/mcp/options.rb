# lib/otto/mcp/options.rb
#
# frozen_string_literal: true

class Otto
  module MCP
    # Normalization of MCP configuration options.
    #
    # Otto.new and Otto#enable_mcp! historically accepted different spellings
    # of the same settings and the constructor dropped all but the endpoint
    # (issue #258). Every path now funnels through {.normalize}.
    #
    # One vocabulary: the canonical keys, their +mcp_+-prefixed variants (the
    # constructor needs a namespace inside an options hash that also
    # configures the rest of Otto), and +tool_calls_per_minute+, which is the
    # name the rate-limiting middleware itself uses. Bare generic names such
    # as +endpoint+, +validation+ and +rate_limiting+ are NOT accepted:
    # +rate_limiting:+ is Otto's own general rate-limiting option (a Hash),
    # and the others were documented before #258 but never read.
    #
    # Two strictness rules, selected with the +scope+ argument:
    #
    # +:constructor+ (used by Otto.new / #configure_mcp)
    #   The constructor forwards its ENTIRE options hash here, most of which
    #   configures things other than MCP, so unrecognized keys are ignored.
    #   Unknown +mcp_+-prefixed keys still fail loud, since such a key can
    #   only have been meant for MCP.
    #
    # +:explicit+ (used by Otto#enable_mcp!)
    #   The caller is configuring MCP and nothing else, so any unrecognized
    #   key raises. That turns +enable_mcp!(auth_token: 'x')+ — a
    #   singular-vs-plural typo that silently left the endpoint open — into a
    #   boot failure.
    #
    # Both scopes accept the canonical output of {.normalize}, so normalization
    # is idempotent under either.
    module Options
      # Canonical MCP option keys and every accepted alias.
      # @api private
      OPTION_ALIASES = {
                http_endpoint: %i[http_endpoint mcp_endpoint],
                  auth_tokens: %i[auth_tokens mcp_auth_tokens],
            enable_validation: %i[enable_validation mcp_validation],
         enable_rate_limiting: %i[enable_rate_limiting mcp_rate_limiting],
          requests_per_minute: %i[requests_per_minute mcp_requests_per_minute],
             tools_per_minute: %i[tools_per_minute tool_calls_per_minute mcp_tool_calls_per_minute],
        allow_unauthenticated: %i[allow_unauthenticated mcp_allow_unauthenticated],
      }.freeze

      # @api private
      SCOPES = %i[constructor explicit].freeze

      # Canonical defaults applied when no alias supplies a value.
      # @api private
      OPTION_DEFAULTS = {
                http_endpoint: '/_mcp',
                  auth_tokens: [].freeze,
            enable_validation: true,
         enable_rate_limiting: true,
          requests_per_minute: 60,
             tools_per_minute: 20,
        allow_unauthenticated: false,
      }.freeze

      # +mcp_+-prefixed constructor keys that gate *whether* MCP is enabled
      # rather than configure the server. Recognized in both scopes so neither
      # the unknown-+mcp_+-key guard nor the strict guard rejects them.
      # @api private
      GATING_KEYS = %i[mcp_enabled mcp_http mcp_stdio].freeze

      # Every key {.normalize} recognizes, in either scope.
      # @api private
      RECOGNIZED_KEYS = (OPTION_ALIASES.values.flatten + GATING_KEYS).freeze

      # Normalize a constructor- or #enable_mcp!-style option hash into the
      # single canonical shape consumed by {Otto::MCP::Server#enable!}.
      #
      # +scope+ is positional, not a keyword, so a brace-less hash at the call
      # site (+normalize(auth_tokens: ['t'])+) binds to +opts+ as intended.
      #
      # @param opts [Hash] raw options
      # @param scope [Symbol] :explicit (strict; the default) or :constructor
      #   (permissive about non-MCP keys)
      # @return [Hash] canonical hash with keys :http_endpoint, :auth_tokens,
      #   :enable_validation, :enable_rate_limiting, :requests_per_minute,
      #   :tools_per_minute, :allow_unauthenticated
      # @raise [ArgumentError] on an unrecognized key, conflicting aliases,
      #   values of the wrong type, or auth tokens supplied but empty/blank
      def self.normalize(opts = {}, scope = :explicit)
        raise ArgumentError, "Unknown MCP option scope #{scope.inspect}; expected one of #{SCOPES.inspect}" unless SCOPES.include?(scope)

        opts = opts.to_h
        reject_unrecognized_keys!(opts, scope)

        canonical = OPTION_DEFAULTS.dup
        OPTION_ALIASES.each do |key, key_aliases|
          supplied = key_aliases.select { |a| opts.key?(a) }
          next if supplied.empty?

          values = supplied.map { |a| opts[a] }
          if values.uniq.size > 1
            raise ArgumentError,
                  "Conflicting MCP options for #{key}: " \
                  "#{supplied.map { |a| "#{a}=#{opts[a].inspect}" }.join(', ')}"
          end

          canonical[key] = coerce_option(key, values.first)
        end

        canonical
      end

      # Reject keys the given scope cannot accept.
      #
      # :explicit rejects anything unrecognized. :constructor rejects only
      # unrecognized +mcp_+-prefixed keys, because it is handed Otto's whole
      # options hash and most keys legitimately belong to other subsystems.
      # @api private
      def self.reject_unrecognized_keys!(opts, scope)
        unknown = opts.keys.reject { |k| RECOGNIZED_KEYS.include?(k.to_sym) }
        unknown.select! { |k| k.to_s.start_with?('mcp_') } if scope == :constructor
        return if unknown.empty?

        raise ArgumentError,
              "Unknown MCP option(s): #{unknown.map(&:inspect).join(', ')}. " \
              "Recognized MCP options: #{RECOGNIZED_KEYS.map(&:inspect).join(', ')}"
      end
      private_class_method :reject_unrecognized_keys!

      # @api private
      def self.coerce_option(key, value)
        case key
        when :auth_tokens
          coerce_auth_tokens!(value)
        when :enable_validation, :enable_rate_limiting, :allow_unauthenticated
          coerce_boolean!(key, value)
        when :requests_per_minute, :tools_per_minute
          unless value.is_a?(Integer) && value.positive?
            raise ArgumentError,
                  "MCP #{key} must be a positive Integer, got #{value.inspect}"
          end

          value
        when :http_endpoint
          unless value.is_a?(String) && value.start_with?('/')
            raise ArgumentError,
                  "MCP http_endpoint must be a String path starting with '/', got #{value.inspect}"
          end

          value
        else
          value
        end
      end
      private_class_method :coerce_option

      # Coerce and validate the configured bearer tokens.
      #
      # A literal empty Array is the one accepted "no tokens" spelling: it is
      # unambiguous, and it is what {.normalize} itself emits when the key is
      # omitted, which keeps normalization idempotent. Every other empty shape
      # (+nil+, +''+, +[nil]+, +['']+) raises, because those are what
      # +auth_tokens: ENV['MCP_TOKEN']+ produces when the variable is unset —
      # silently serving the endpoint to anyone.
      # @api private
      def self.coerce_auth_tokens!(value)
        return [] if value.is_a?(Array) && value.empty?

        tokens  = value.is_a?(String) ? [value] : Array(value)
        invalid = tokens.grep_v(String)
        unless invalid.empty?
          raise ArgumentError,
                "MCP auth_tokens must be Strings, got #{invalid.map(&:class).uniq.join(', ')}"
        end

        raise_empty_auth_tokens!(value) if tokens.empty?

        blank = tokens.select { |token| token.strip.empty? }
        unless blank.empty?
          raise ArgumentError,
                "MCP auth_tokens must not be blank, got #{blank.map(&:inspect).join(', ')}. " \
                'A blank token cannot be presented by a client and would not protect the endpoint.'
        end

        tokens
      end
      private_class_method :coerce_auth_tokens!

      # @api private
      def self.raise_empty_auth_tokens!(value)
        raise ArgumentError,
              "MCP auth_tokens was supplied as #{value.inspect} but resolves to no tokens. " \
              "This is what auth_tokens: ENV['MCP_TOKEN'] does when the variable is unset, " \
              'and it would expose the MCP endpoint to any caller. Supply at least one token, ' \
              'or omit auth_tokens entirely and pass allow_unauthenticated: true to serve the ' \
              'endpoint without authentication on purpose.'
      end
      private_class_method :raise_empty_auth_tokens!

      # @api private
      def self.coerce_boolean!(key, value)
        return value if [true, false].include?(value)

        raise ArgumentError, "MCP #{key} must be true or false, got #{value.inspect}"
      end
      private_class_method :coerce_boolean!
    end
  end
end
