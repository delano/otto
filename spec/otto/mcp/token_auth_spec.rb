# frozen_string_literal: true

require_relative '../../spec_helper'

RSpec.describe Otto::MCP::Auth::TokenAuth do
  subject(:auth) { described_class.new(%w[abc def]) }

  describe '#authenticate' do
    it 'authenticates a valid bearer token' do
      env = { 'HTTP_AUTHORIZATION' => 'Bearer def' }
      expect(auth.authenticate(env)).to be(true)
    end

    it 'authenticates a valid X-MCP-Token header' do
      env = { 'HTTP_X_MCP_TOKEN' => 'abc' }
      expect(auth.authenticate(env)).to be(true)
    end

    it 'rejects an incorrect token' do
      env = { 'HTTP_AUTHORIZATION' => 'Bearer nope' }
      expect(auth.authenticate(env)).to be(false)
    end

    it 'rejects when no token is provided' do
      expect(auth.authenticate({})).to be(false)
    end

    it 'rejects any token when no tokens are configured' do
      empty_auth = described_class.new([])
      env = { 'HTTP_AUTHORIZATION' => 'Bearer anything' }
      expect(empty_auth.authenticate(env)).to be(false)
    end
  end
end
