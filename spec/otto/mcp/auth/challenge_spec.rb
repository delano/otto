# spec/otto/mcp/auth/challenge_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::MCP::Auth::Challenge do
  describe '.metadata_url' do
    {
      'https://mcp.example.com/mcp' => 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp',
      'https://example.com/public/mcp' => 'https://example.com/.well-known/oauth-protected-resource/public/mcp',
      'https://mcp.example.com' => 'https://mcp.example.com/.well-known/oauth-protected-resource',
      'https://mcp.example.com/' => 'https://mcp.example.com/.well-known/oauth-protected-resource',
      'https://mcp.example.com:8443/mcp' => 'https://mcp.example.com:8443/.well-known/oauth-protected-resource/mcp',
      'http://localhost:9292/_mcp' => 'http://localhost:9292/.well-known/oauth-protected-resource/_mcp',
      'https://mcp.example.com/mcp?tenant=a' => 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp?tenant=a',
    }.each do |resource, expected|
      it "places the document for #{resource} at #{expected}" do
        expect(described_class.metadata_url(resource)).to eq(expected)
      end
    end
  end

  describe '.bearer' do
    it 'escapes quotes and backslashes in a parameter value' do
      expect(described_class.bearer(resource_metadata: 'https://x.example/a"b\\c'))
        .to eq('Bearer resource_metadata="https://x.example/a\\"b\\\\c"')
    end
  end
end
