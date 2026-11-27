# spec/otto/mcp/request_state_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::MCP::RequestState do
  subject(:codec) { described_class.new(secret) }

  let(:secret)  { 'k' * 32 }
  let(:binding) { 'alice / tools/call / arrange / digest' }
  let(:data)    { { 'operation_id' => 'op_123', 'steps' => [1, 2] } }
  let(:now)     { Time.at(1_800_000_000) }

  def sealed(ttl: 60)
    codec.seal(data, binding: binding, ttl: ttl, now: now)
  end

  it 'returns the data to the same caller making the same call' do
    expect(codec.open(sealed, binding: binding, now: now + 59)).to eq(data)
  end

  it 'produces a value that does not reveal the data' do
    value = sealed

    expect(value).to start_with('v1.')
    expect(value).to match(/\Av1\.[A-Za-z0-9_-]+\z/)
    expect(value).not_to include('op_123')
    expect(value.delete_prefix('v1.').tr('-_', '+/').unpack1('m')).not_to include('op_123')
  end

  it 'seals the same data differently each time' do
    expect(sealed).not_to eq(sealed)
  end

  it 'refuses a state bound to another caller or call' do
    expect { codec.open(sealed, binding: 'bob / tools/call / arrange / digest', now: now) }
      .to raise_error(Otto::MCP::InvalidRequestStateError)
  end

  it 'refuses a state once its ttl has passed' do
    expect { codec.open(sealed(ttl: 60), binding: binding, now: now + 60) }
      .to raise_error(Otto::MCP::InvalidRequestStateError, 'expired')
  end

  it 'refuses a state sealed under another secret' do
    other = described_class.new('z' * 32).seal(data, binding: binding, ttl: 60, now: now)

    expect { codec.open(other, binding: binding, now: now) }.to raise_error(Otto::MCP::InvalidRequestStateError)
  end

  # This includes the last character, whose spare bits decode to the same
  # bytes: one state has one spelling.
  it 'refuses a state with any character changed' do
    encoded = sealed.delete_prefix('v1.')

    encoded.length.times do |index|
      tampered        = encoded.dup
      tampered[index] = encoded[index] == 'A' ? 'B' : 'A'

      expect { codec.open("v1.#{tampered}", binding: binding, now: now) }
        .to raise_error(Otto::MCP::InvalidRequestStateError), "character #{index} was accepted"
    end
  end

  it 'refuses a state with padding or standard Base64 characters added' do
    encoded = sealed.delete_prefix('v1.')

    ["#{encoded}=", "#{encoded}==", encoded.tr('-_', '+/')].reject { |variant| variant == encoded }.each do |variant|
      expect { codec.open("v1.#{variant}", binding: binding, now: now) }.to raise_error(Otto::MCP::InvalidRequestStateError)
    end
  end

  [nil, 42, '', 'v1.', 'v1.AAAA', 'v2.abcdef', 'not-a-state', 'v1.has spaces', "v1.#{'A' * 20_000}"].each do |invalid|
    it "refuses #{invalid.inspect[0, 24]}" do
      expect { codec.open(invalid, binding: binding, now: now) }.to raise_error(Otto::MCP::InvalidRequestStateError)
    end
  end

  it 'is a bad request, so an unhandled one is not reported as a server fault' do
    expect(Otto::MCP::InvalidRequestStateError.ancestors).to include(Otto::BadRequestError)
  end

  it 'does not print its key' do
    expect(codec.inspect).to eq('#<Otto::MCP::RequestState>')
  end

  it 'runs the first-seal hook once' do
    calls = 0
    codec = described_class.new(secret, on_first_seal: -> { calls += 1 })

    3.times { codec.seal(data, binding: binding, ttl: 60) }

    expect(calls).to eq(1)
  end
end
