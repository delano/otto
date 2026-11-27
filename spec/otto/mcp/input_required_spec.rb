# spec/otto/mcp/input_required_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::MCP::InputRequired do
  let(:arguments) { { url: 'https://example.com/handoffs/pending', message: 'Enter the secret on example.com.' } }

  it 'builds a URL elicitation request under the given key' do
    required = described_class.url('handoff', **arguments, state: { 'operation_id' => 'op_1' })

    expect(required.requests).to eq('handoff' => {
                                      'method' => 'elicitation/create',
                                      'params' => { 'mode' => 'url', 'url' => 'https://example.com/handoffs/pending', 'message' => 'Enter the secret on example.com.' },
                                    })
    expect(required.state).to eq('operation_id' => 'op_1')
    expect(required.ttl).to eq(described_class::DEFAULT_TTL)
    expect(required.required_capabilities).to eq('elicitation' => { 'url' => {} })
  end

  it 'accepts a state up to MAX_STATE_BYTES of JSON, which still fits when sealed' do
    largest = { 'k' => 'a' * (described_class::MAX_STATE_BYTES - 8) }
    codec   = Otto::MCP::RequestState.new('s' * 32)

    required = described_class.url('handoff', **arguments, state: largest)
    sealed   = codec.seal(required.state, binding: 'b', ttl: 60)

    expect(JSON.generate(largest).bytesize).to eq(described_class::MAX_STATE_BYTES)
    expect(codec.open(sealed, binding: 'b')).to eq(largest)
  end

  it 'refuses a larger state when the request is built, not when the client retries' do
    expect { described_class.url('handoff', **arguments, state: { 'k' => 'a' * described_class::MAX_STATE_BYTES }) }
      .to raise_error(ArgumentError, /state must be at most 8192 bytes of JSON/)
  end

  it 'has an empty state when none is given' do
    expect(described_class.url('handoff', **arguments).state).to eq({})
  end

  {
    'a blank key' => [' ', {}],
    'a non-String key' => [:handoff, {}],
    'a relative URL' => ['k', { url: '/handoffs/pending' }],
    'a URL with another scheme' => ['k', { url: 'javascript:alert(1)' }],
    'a URL with no host' => ['k', { url: 'https:///path' }],
    'a URL that does not parse' => ['k', { url: 'https://exa mple.com' }],
    'a blank message' => ['k', { message: '' }],
    'a state that is not a Hash' => ['k', { state: 'op_1' }],
    'a ttl of zero' => ['k', { ttl: 0 }],
    'a ttl over the maximum' => ['k', { ttl: described_class::MAX_TTL + 1 }],
  }.each do |label, (key, overrides)|
    it "refuses #{label}" do
      expect { described_class.url(key, **arguments, **overrides) }.to raise_error(ArgumentError, /MCP input request/)
    end
  end
end
