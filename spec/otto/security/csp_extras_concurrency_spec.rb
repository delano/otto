# spec/otto/security/csp_extras_concurrency_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# No-bleed guarantee for request-scoped CSP extras (delano/otto#243): extras
# live in the Rack env ONLY, so two concurrent requests through the same
# (shared, potentially frozen) Security::Config must each get exactly their own
# tokens. Modeled on the issue #188 pattern (route_class_otto_accessor_spec):
# the interleaving is forced deterministically with Queue handoffs rather than
# sleeps, and each thread's outcome is read after join.
# Behavioural concurrency spec (not one class under test); the threads and the
# example length are the point — deterministic interleaving needs the whole
# choreography in one example, exactly like route_class_otto_accessor_spec.
# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, ThreadSafety/NewThread
RSpec.describe 'CSP request extras under concurrent requests' do
  it 'gives two interleaved requests exactly their own extras (no bleed)' do
    config = Otto::Security::Config.new
    config.enable_csp_with_nonce!
    config.deep_freeze! # the production condition: one shared frozen config

    env_a = { 'otto.csp.extra_directives' => { 'form-action' => ['https://tenant-a.example'] } }
    env_b = { 'otto.csp.extra_directives' => { 'form-action' => ['https://tenant-b.example'] } }
    headers_a = { 'content-type' => 'text/html' }
    headers_b = { 'content-type' => 'text/html' }
    result_a = nil
    result_b = nil

    # Forced order: A applies, THEN B applies (any shared per-config/class
    # state would now carry B's extras), and only THEN does A re-apply onto a
    # fresh response for the same request env — so leakage in either direction
    # is observable, not timing-dependent.
    a_applied = Queue.new
    b_applied = Queue.new
    headers_a2 = { 'content-type' => 'text/html' }
    result_a2 = nil

    thread_a = Thread.new do
      begin
        result_a = Otto::Security::CSP::Writer.apply(headers_a, 'NA', config: config, env: env_a)
      ensure
        a_applied.push(true) # let thread_b apply now
      end

      b_applied.pop # wait until thread_b applied (would have clobbered shared state)
      result_a2 = Otto::Security::CSP::Writer.apply(headers_a2, 'NA', config: config, env: env_a)
    end

    thread_b = Thread.new do
      a_applied.pop # wait until thread_a has applied

      begin
        result_b = Otto::Security::CSP::Writer.apply(headers_b, 'NB', config: config, env: env_b)
      ensure
        b_applied.push(true) # release thread_a to re-apply and observe
      end
    end

    [thread_a, thread_b].each(&:join)
    [thread_a, thread_b].each(&:value)

    aggregate_failures do
      expect(headers_a['content-security-policy']).to include('https://tenant-a.example')
      expect(headers_a['content-security-policy']).not_to include('tenant-b')
      expect(headers_b['content-security-policy']).to include('https://tenant-b.example')
      expect(headers_b['content-security-policy']).not_to include('tenant-a')
      # The re-apply AFTER b's request still sees only a's extras.
      expect(headers_a2['content-security-policy']).to include('https://tenant-a.example')
      expect(headers_a2['content-security-policy']).not_to include('tenant-b')

      expect(result_a.extra_directives).to eq('form-action' => ['https://tenant-a.example'])
      expect(result_b.extra_directives).to eq('form-action' => ['https://tenant-b.example'])
      expect(result_a2.extra_directives).to eq('form-action' => ['https://tenant-a.example'])

      # And nothing landed on the shared config.
      expect(config.csp_directive_overrides).to eq({})
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, ThreadSafety/NewThread
