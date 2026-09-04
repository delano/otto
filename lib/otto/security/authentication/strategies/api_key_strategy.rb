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
        # Accepts exactly one key source: a static list (`api_keys:`), a
        # callable (`resolver:`), or a block. A resolver receives the presented
        # key (a non-empty String, never env) and returns the account behind it,
        # or nil/false when the key is unknown. Any other return value, including
        # an empty container, counts as a match: an ORM relation from `where`,
        # an empty Array from `select`, or `{}` from a cache miss is truthy and
        # authenticates the caller. Return exactly one record (`find_by`,
        # `first`) or nil. The strategy never branches on mode: a static list is
        # wrapped in a resolver internally.
        #
        # Fails closed: a strategy with no source, or a static list with no
        # non-empty key, is a misconfiguration and raises ArgumentError at
        # construction rather than authenticating every caller. Only a truthy
        # resolver return (for a static list: a constant-time match) grants
        # success.
        #
        # A credential that was presented and rejected, including a non-String
        # credential such as an array query parameter, fails TERMINALLY, so a bad
        # key halts the strategy chain instead of falling through to a later
        # anonymous-capable strategy. A missing credential fails non-terminally.
        # Blank and non-String credentials are rejected before the resolver runs.
        #
        # Exceptions raised by a resolver propagate. A database outage must
        # surface as an error, not as a silent 401 and never as success.
        #
        # Timing: the static list is compared in constant time against every
        # configured key. A black-box lookup cannot be made constant-time by the
        # strategy; the documented pattern is to store SHA-256 digests and look
        # up by {APIKeyStrategy.digest}, which is constant-time by construction
        # and keeps raw keys out of the database.
        #
        # The result never carries the raw key: it exposes only a short SHA-256
        # fingerprint, so the secret does not reach env, session, or logs.
        #
        # The query/form parameter path is opt-in (`param_name:`), because keys in
        # URLs are recorded by access logs, proxies, and browser history.
        #
        # Scope: this is a small static-allowlist authenticator shipped as a
        # low-dependency convenience and reference implementation. It has no
        # native support for runtime addition or revocation, expiration, roles
        # or scopes, key metadata, quotas, a management API, audit history, or
        # hashed verifier storage. The resolver form delegates those concerns
        # to the application's key store; see docs/guides/authentication.md.
        #
        # @example Static list, header only (recommended)
        #   APIKeyStrategy.new(api_keys: ['secret123'])
        # @example Block resolver looking up a stored digest
        #   APIKeyStrategy.new do |presented_key|
        #     ApiKey.find_by(digest: APIKeyStrategy.digest(presented_key))&.account
        #   end
        # @example Callable resolver (anything responding to #call)
        #   APIKeyStrategy.new(resolver: repo.method(:find_by_key))
        # @example Also accept ?api_key= (logged in URLs; prefer the header)
        #   APIKeyStrategy.new(api_keys: ['secret123'], param_name: 'api_key')
        class APIKeyStrategy < AuthStrategy
          # Full SHA-256 hex digest of a key. Store this instead of the raw key
          # and look up presented keys by their digest.
          #
          # @param key [String]
          # @return [String] 64-char hex digest
          def self.digest(key)
            Digest::SHA256.hexdigest(key)
          end

          # @param api_keys [String, Array<String>, nil] static list of valid API keys
          # @param resolver [#call, nil] callable receiving the presented key and
          #   returning the account (truthy) or nil/false when unknown
          # @param header_name [String] request header carrying the key
          # @param param_name [String, nil] query/form parameter carrying the key.
          #   Defaults to nil (header only): keys placed in a URL are captured by
          #   access logs, proxies, and browser history. Pass 'api_key' to opt in.
          # @yieldparam presented_key [String] the non-empty presented key
          # @yieldreturn [Object, nil, false] the account behind the key, or
          #   nil/false when the key is unknown
          # @raise [ArgumentError] if no source, or more than one, is given
          # @raise [ArgumentError] if resolver: does not respond to #call
          # @raise [ArgumentError] if api_keys: contains no non-empty API key
          def initialize(api_keys: nil, resolver: nil, header_name: 'X-API-Key', param_name: nil, &block)
            super()
            @resolver = build_resolver(api_keys, resolver, block)
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
            # still presented, so reject it terminally rather than handing it to
            # the resolver. Credentials were explicitly presented and rejected:
            # fail closed.
            return failure('Invalid API key', terminal: true) unless api_key.is_a?(String)

            # Resolver exceptions propagate deliberately (see class docs).
            user = @resolver.call(api_key)
            return failure('Invalid API key', terminal: true) unless user

            # Identify the credential by a non-reversible fingerprint. The raw key
            # must not reach the result, since it flows into env, session, and logs.
            success(user: user,
                    auth_method: 'api_key',
                    api_key_fingerprint: key_fingerprint(api_key))
          end

          private

          def build_resolver(api_keys, resolver, block)
            sources = [api_keys, resolver, block].count { |source| !source.nil? }
            if sources > 1
              raise ArgumentError,
                    'APIKeyStrategy: pass api_keys:, resolver:, or a block, not more than one'
            end
            # `api_keys: nil` and omitting every source are indistinguishable
            # here, so one message covers both.
            if sources.zero?
              raise ArgumentError,
                    'APIKeyStrategy requires a key source: at least one non-empty API key ' \
                    '(api_keys:), a resolver:, or a block'
            end

            return static_resolver(api_keys) unless api_keys.nil?
            return block if block

            raise ArgumentError, 'APIKeyStrategy resolver: must respond to #call' unless resolver.respond_to?(:call)

            resolver
          end

          # Wrap a static key list in a resolver performing a constant-time,
          # non-short-circuiting membership check.
          def static_resolver(api_keys)
            keys = Array(api_keys).map(&:to_s).reject(&:empty?).freeze
            if keys.empty?
              raise ArgumentError,
                    'APIKeyStrategy requires at least one non-empty API key ' \
                    '(api_keys: was empty or contained only blank values)'
            end

            lambda do |presented|
              matched = keys.reduce(false) do |acc, key|
                Rack::Utils.secure_compare(key, presented) || acc
              end
              matched ? { api_key_fingerprint: key_fingerprint(presented) } : nil
            end
          end

          # Short, non-reversible identifier for a key: enough to correlate
          # requests and audit logs without exposing the credential.
          def key_fingerprint(api_key)
            self.class.digest(api_key)[0, 12]
          end
        end
      end
    end
  end
end
