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
  # @example Tryouts (setup section of each file)
  #   require 'otto/testing'
  #   Otto::Testing.reset!
  module Testing
    # Stands in for the application behind IPPrivacyMiddleware; only the env
    # the middleware leaves behind is of interest.
    RESOLVED_APP = ->(_env) { [200, {}, []] }
    private_constant :RESOLVED_APP

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
    # Pass the application's security config (otto.security_config) so the
    # privacy profile and proxy trust match the app under test. Without one,
    # Otto's defaults apply: public addresses masked, no proxy trust.
    #
    # For a request relayed by a proxy, build the env with REMOTE_ADDR and
    # the forwarded headers and call {.resolve_client_ip!} instead.
    #
    # @param uri [String] passed to Rack::MockRequest.env_for
    # @param client_ip [String, nil] the connecting address; nil builds a
    #   request with no resolvable client IP, whose otto.ip_match denies
    #   every range and which has no otto.client_ip
    # @param security_config [Otto::Security::Config, nil]
    # @param rack_options [Hash] remaining Rack::MockRequest.env_for options
    #   (method:, params:, input:, and String env keys such as
    #   'HTTP_USER_AGENT')
    # @return [Hash] the env
    #
    # @example
    #   env = Otto::Testing.env_for('/admin', client_ip: '203.0.113.9',
    #                               security_config: otto.security_config)
    #   env['otto.client_ip']                          # => "203.0.113.0"
    #   env['otto.ip_match'].call(['203.0.113.9/32'])  # => true
    def env_for(uri = '/', client_ip:, security_config: nil, **rack_options)
      env = Rack::MockRequest.env_for(uri, rack_options)
      if client_ip.nil?
        env.delete('REMOTE_ADDR')
      else
        env['REMOTE_ADDR'] = client_ip
      end
      resolve_client_ip!(env, security_config)
    end

    # Run IPPrivacyMiddleware over an existing env, in place, so it carries
    # the keys the middleware writes, all derived from one resolution.
    #
    # @param env [Hash] Rack env, with REMOTE_ADDR and any forwarded headers
    # @param security_config [Otto::Security::Config, nil] see {.env_for}
    # @return [Hash] the same env
    def resolve_client_ip!(env, security_config = nil)
      Otto::Security::Middleware::IPPrivacyMiddleware.new(RESOLVED_APP, security_config).call(env)
      env
    end
  end
end
