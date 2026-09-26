# lib/otto/testing.rb
#
# frozen_string_literal: true

require 'rack/mock'
require_relative '../otto'

class Otto
  # Test support for applications built on Otto, independent of the test
  # framework. `require 'otto'` does not load this file; require
  # 'otto/testing' from a test helper. Loading it is the opt-in for the
  # resets below, which production code must never call.
  #
  # @example RSpec
  #   require 'otto/testing'
  #   RSpec.configure { |c| c.before { Otto::Testing.reset! } }
  #
  # @example Minitest
  #   require 'otto/testing'
  #   class Minitest::Test
  #     def before_setup
  #       super
  #       Otto::Testing.reset!
  #     end
  #   end
  #
  # @example Tryouts (setup runs once per file, so reset inside each case)
  #   ## a depth-mode app reading Forwarded
  #   Otto::Testing.reset!
  #   Otto.new(nil, trusted_proxy_depth: 1, trusted_proxy_header: 'Forwarded')
  module Testing
    # Stands in for the application behind IPPrivacyMiddleware; only the env
    # the middleware leaves behind is of interest.
    RESOLVED_APP = ->(_env) { [200, {}, []] }
    private_constant :RESOLVED_APP

    # Headers the client-IP resolver can read an address from. A request
    # carrying one is relayed, not direct, so .env_for refuses them.
    FORWARDED_IP_HEADERS = (Otto::Utils::FORWARDED_FOR_HEADERS + %w[HTTP_FORWARDED]).freeze
    private_constant :FORWARDED_IP_HEADERS

    module_function

    # Clear the process-global state Otto accumulates across Otto.new calls,
    # so one test's applications cannot decide whether the next test's raise.
    #
    # Today that is the forwarding-family registry and
    # Rack::Request.forwarded_priority, which Otto pins from
    # trusted_proxy_header. Rack's setting is one per process, so a second
    # application choosing a different family raises ArgumentError; in a
    # suite that builds applications with different families, the outcome
    # would otherwise depend on test order.
    #
    # Call it before every test (or after every test), not once per suite.
    #
    # @return [nil]
    def reset!
      Otto::Security::Config.send(:reset_rack_forwarding_family!)
      nil
    end

    # Build a Rack env as IPPrivacyMiddleware leaves it for a request arriving
    # directly from client_ip: env['otto.client_ip'] (masked under the
    # privacy profile in force), env['otto.ip_match'] over the unmasked
    # address, the rewritten REMOTE_ADDR, and the proxy-trust verdict when
    # trust is configured.
    #
    # Use it instead of writing env['otto.client_ip'] by hand. A hand-written
    # value looks to the middleware like a prior pass, so the precise
    # otto.ip_match is never built and every CIDR check denies.
    #
    # security_config is required because the app's own IPPrivacyMiddleware
    # keeps whatever this resolution produced: pass the application's
    # (otto.security_config) so the privacy profile and proxy trust match the
    # app under test. nil means an unconfigured middleware: public addresses
    # masked, no proxy trust.
    #
    # The request is direct, so forwarded-for headers (X-Forwarded-For,
    # X-Real-IP, X-Client-IP, Forwarded) raise ArgumentError: under a config
    # that trusts the peer they would move the resolved address away from
    # client_ip. For a relayed request, build the env with REMOTE_ADDR and the
    # forwarded headers and call {.resolve_client_ip!}.
    #
    # @param uri [String] passed to Rack::MockRequest.env_for
    # @param client_ip [String, nil] the connecting address; nil builds a
    #   request with no resolvable client IP, whose otto.ip_match denies
    #   every range and whose env['otto.client_ip'] is nil
    # @param security_config [Otto::Security::Config, nil]
    # @param rack_options [Hash] remaining Rack::MockRequest.env_for options
    #   (method:, params:, input:, and String env keys such as
    #   'HTTP_USER_AGENT')
    # @return [Hash] the env
    # @raise [ArgumentError] if rack_options carry a forwarded-for header
    #
    # @example
    #   env = Otto::Testing.env_for('/admin', client_ip: '203.0.113.9',
    #                               security_config: otto.security_config)
    #   env['otto.client_ip']                          # => "203.0.113.0"
    #   env['otto.ip_match'].call(['203.0.113.9/32'])  # => true
    def env_for(uri = '/', client_ip:, security_config:, **rack_options)
      forwarded = FORWARDED_IP_HEADERS & rack_options.keys
      unless forwarded.empty?
        raise ArgumentError, "env_for builds a direct request from client_ip; #{forwarded.join(', ')} " \
                             'would change which address resolves. Build the env yourself and call ' \
                             'Otto::Testing.resolve_client_ip! for a relayed request.'
      end

      env = Rack::MockRequest.env_for(uri, rack_options)
      if client_ip.nil?
        env.delete('REMOTE_ADDR')
      else
        env['REMOTE_ADDR'] = client_ip
      end
      resolve_client_ip!(env, security_config)
    end

    # Run IPPrivacyMiddleware over an existing env, in place, so it carries
    # the keys the middleware writes, all derived from one resolution. Use it
    # for relayed requests: REMOTE_ADDR is the proxy and the forwarded headers
    # carry the client.
    #
    # Pass the application's security config. Its proxy trust decides whether
    # the forwarded headers are read at all; resolved without it, the proxy
    # becomes the client, and the app's middleware keeps that result.
    #
    # @param env [Hash] Rack env, with REMOTE_ADDR and any forwarded headers
    # @param security_config [Otto::Security::Config, nil] see {.env_for}
    # @return [Hash] the same env
    # @raise [ArgumentError] if env was already resolved, since the
    #   middleware would keep the earlier result instead of applying
    #   security_config
    def resolve_client_ip!(env, security_config)
      if env.key?('otto.client_ip') || env.key?('otto.ip_match')
        raise ArgumentError, 'env already carries otto.client_ip or otto.ip_match, so IPPrivacyMiddleware ' \
                             'would keep that result instead of resolving under this security_config'
      end

      Otto::Security::Middleware::IPPrivacyMiddleware.new(RESOLVED_APP, security_config).call(env)
      env
    end
  end
end
