# spec/otto/mcp/call_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::MCP::Call do
  it 'defaults to a first call from a client that declared nothing' do
    call = described_class.new(protocol_version: '2026-07-28')

    expect(call).to have_attributes(auth: nil, client_capabilities: {}, client_info: nil, input_responses: {}, state: nil)
    expect(call).not_to be_url_elicitation
    expect(call).not_to be_retry
  end

  it 'reads URL elicitation support only from an explicit url member' do
    supports = ->(capabilities) { described_class.new(protocol_version: '2026-07-28', client_capabilities: capabilities).url_elicitation? }

    expect(supports.call('elicitation' => { 'url' => {} })).to be(true)
    expect(supports.call('elicitation' => { 'form' => {}, 'url' => {} })).to be(true)
    # "an empty capabilities object is equivalent to declaring support for
    # form mode only"
    expect(supports.call('elicitation' => {})).to be(false)
    expect(supports.call('elicitation' => { 'form' => {} })).to be(false)
    expect(supports.call('elicitation' => { 'url' => true })).to be(false)
    expect(supports.call('elicitation' => 'url')).to be(false)
  end

  it 'is a retry once it has a state, even an empty one' do
    expect(described_class.new(protocol_version: '2026-07-28', state: {})).to be_retry
  end

  it 'reports what the client says the person did, and nothing for a malformed response' do
    call = described_class.new(protocol_version: '2026-07-28', input_responses: {
                                 'a' => { 'action' => 'accept' }, 'b' => { 'action' => 'decline' }, 'c' => 'accept', 'd' => { 'action' => 1 }
                               })

    expect(%w[a b c d e].map { |key| call.input_action(key) }).to eq(['accept', 'decline', nil, nil, nil])
  end
end
