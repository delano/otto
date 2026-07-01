# spec/otto/security/csp/parser_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe Otto::Security::CSP::Parser do
  describe '.parse' do
    context 'legacy application/csp-report format' do
      let(:body) do
        {
          'csp-report' => {
            'document-uri' => 'https://example.com/page',
            'violated-directive' => 'script-src',
            'blocked-uri' => 'https://evil.example/x',
            'line-number' => 42,
          },
        }.to_json
      end

      it 'returns a single normalized report' do
        reports = described_class.parse(body, 'application/csp-report')

        expect(reports.length).to eq(1)
        expect(reports.first).to be_a(Otto::Security::CSP::Report)
        expect(reports.first.violated_directive).to eq('script-src')
        expect(reports.first.blocked_uri).to eq('https://evil.example/x')
        expect(reports.first.line_number).to eq(42)
      end
    end

    context 'Reporting API application/reports+json format' do
      let(:body) do
        [
          {
            'type' => 'csp-violation',
            'body' => {
              'documentURL' => 'https://example.com/page',
              'effectiveDirective' => 'img-src',
              'blockedURL' => 'https://cdn.evil/x',
            },
          },
          {
            'type' => 'csp-violation',
            'body' => {
              'documentURL' => 'https://example.com/other',
              'effectiveDirective' => 'style-src',
            },
          },
        ].to_json
      end

      it 'returns one normalized report per array entry' do
        reports = described_class.parse(body, 'application/reports+json')

        expect(reports.length).to eq(2)
        expect(reports.map(&:effective_directive)).to contain_exactly('img-src', 'style-src')
      end

      it 'ignores non-csp-violation entries in the batch' do
        mixed = [
          { 'type' => 'deprecation', 'body' => { 'id' => 'x' } },
          { 'type' => 'csp-violation', 'body' => { 'effectiveDirective' => 'font-src' } },
          { 'type' => 'intervention', 'body' => { 'id' => 'y' } },
        ].to_json

        reports = described_class.parse(mixed, 'application/reports+json')
        expect(reports.length).to eq(1)
        expect(reports.first.effective_directive).to eq('font-src')
      end

      it 'accepts an untyped entry that still carries a body' do
        untyped = [{ 'body' => { 'effectiveDirective' => 'connect-src' } }].to_json
        reports = described_class.parse(untyped, 'application/reports+json')

        expect(reports.length).to eq(1)
        expect(reports.first.effective_directive).to eq('connect-src')
      end
    end

    context 'a single un-wrapped Reporting API object (not in an array)' do
      it 'still parses the body' do
        body = { 'body' => { 'effectiveDirective' => 'media-src' } }.to_json
        reports = described_class.parse(body, 'application/reports+json')

        expect(reports.length).to eq(1)
        expect(reports.first.effective_directive).to eq('media-src')
      end
    end

    context 'malformed and empty input' do
      it 'returns [] for malformed JSON without raising' do
        expect { described_class.parse('{not valid json', nil) }.not_to raise_error
        expect(described_class.parse('{not valid json', nil)).to eq([])
      end

      it 'returns [] for nil and empty bodies' do
        expect(described_class.parse(nil, nil)).to eq([])
        expect(described_class.parse('', nil)).to eq([])
      end

      it 'returns [] for a JSON scalar/unexpected top-level type' do
        expect(described_class.parse('"just a string"', nil)).to eq([])
        expect(described_class.parse('123', nil)).to eq([])
        expect(described_class.parse('null', nil)).to eq([])
      end

      it 'returns [] for a Hash that is neither wire format' do
        expect(described_class.parse({ 'foo' => 'bar' }.to_json, nil)).to eq([])
      end

      it 'returns [] for an empty Reporting API array' do
        expect(described_class.parse('[]', nil)).to eq([])
      end
    end

    it 'does not depend on the content_type argument to disambiguate' do
      # A legacy body labelled with the Reporting API content type still parses.
      body = { 'csp-report' => { 'violated-directive' => 'script-src' } }.to_json
      reports = described_class.parse(body, 'application/reports+json')

      expect(reports.length).to eq(1)
      expect(reports.first.violated_directive).to eq('script-src')
    end
  end
end
