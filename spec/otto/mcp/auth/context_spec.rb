# spec/otto/mcp/auth/context_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::MCP::Auth::Context do
  subject(:context) do
    described_class.new(subject: 'cust_1', client_id: 'client_a', tenant: 'org_9',
                        scopes: 'handoff:read handoff:write', audience: 'https://mcp.example.com/mcp',
                        claims: { 'email' => 'person@example.com' })
  end

  it 'splits a space-delimited scope claim' do
    expect(context.scopes).to eq(%w[handoff:read handoff:write])
  end

  it 'accepts scopes as an Array or a Set, without duplicates' do
    expect(described_class.new(subject: 's', scopes: %w[a b a]).scopes).to eq(%w[a b])
    expect(described_class.new(subject: 's', scopes: Set['a']).scopes).to eq(%w[a])
  end

  it 'wraps a single audience in an Array' do
    expect(context.audience).to eq(['https://mcp.example.com/mcp'])
  end

  it 'is deeply immutable' do
    expect(context).to be_frozen
    expect([context.subject, context.scopes, context.audience, context.claims]).to all(be_frozen)
    expect { context.scopes << 'admin' }.to raise_error(FrozenError)
  end

  it 'does not share state with the values it was built from' do
    subject_name = +'cust_1'
    built        = described_class.new(subject: subject_name)
    subject_name << '_changed'

    expect(built.subject).to eq('cust_1')
  end

  [nil, '', '   ', 42, :cust].each do |invalid|
    it "refuses #{invalid.inspect} as the subject" do
      expect { described_class.new(subject: invalid) }.to raise_error(ArgumentError, /subject must be a non-blank String/)
    end
  end

  describe '#grants?' do
    it 'is true only when every required scope was granted' do
      expect(context.grants?(%w[handoff:read])).to be(true)
      expect(context.grants?(%w[handoff:read handoff:write])).to be(true)
      expect(context.grants?(%w[handoff:read admin])).to be(false)
    end

    it 'is true when nothing is required' do
      expect(described_class.new(subject: 's').grants?([])).to be(true)
    end
  end

  describe '#issued_for?' do
    it 'compares the resource URI exactly' do
      expect(context.issued_for?('https://mcp.example.com/mcp')).to be(true)
      expect(context.issued_for?('https://mcp.example.com/mcp/')).to be(false)
      expect(context.issued_for?('https://mcp.example.com')).to be(false)
    end
  end

  describe '#principal_key' do
    it 'differs when the subject, the client or the tenant differs' do
      keys = [
        context,
        context.with(subject: 'cust_2'),
        context.with(client_id: 'client_b'),
        context.with(tenant: 'org_8'),
      ].map(&:principal_key)

      expect(keys.uniq.size).to eq(4)
    end

    it 'keeps the members apart whatever characters they contain' do
      keys = [
        described_class.new(subject: 'a', client_id: 'b'),
        described_class.new(subject: 'a', tenant: 'b'),
        described_class.new(subject: "a\x1fb"),
        described_class.new(subject: 'a","b'),
        described_class.new(subject: 'a'),
      ].map(&:principal_key)

      expect(keys.uniq.size).to eq(5)
    end
  end

  describe 'issuer' do
    it 'is absent unless the authenticator gives one' do
      expect(context.issuer).to be_nil
      expect(context.with(issuer: 'https://auth.example.com').issuer).to eq('https://auth.example.com')
    end

    it 'tells apart the same subject at two authorization servers' do
      first  = context.with(issuer: 'https://auth-one.example.com')
      second = context.with(issuer: 'https://auth-two.example.com')

      expect([context, first, second].map(&:principal_key).uniq.size).to eq(3)
    end
  end

  describe '#inspect' do
    it 'leaves the claims out' do
      expect(context.inspect).to include('cust_1', 'client_a', 'org_9', 'handoff:read')
      expect(context.inspect).not_to include('person@example.com')
      expect(context.to_s).not_to include('person@example.com')
    end
  end
end
