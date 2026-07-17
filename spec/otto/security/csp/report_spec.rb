# spec/otto/security/csp/report_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Security::CSP::Report do
  describe '.from_raw' do
    context 'with a legacy (kebab-case) report hash' do
      let(:raw) do
        {
          'document-uri' => 'https://example.com/page',
          'referrer' => 'https://example.com/',
          'blocked-uri' => 'inline',
          'violated-directive' => 'script-src',
          'effective-directive' => 'script-src-elem',
          'original-policy' => "default-src 'self'",
          'disposition' => 'report',
          'source-file' => 'https://example.com/app.js',
          'status-code' => '200',
          'script-sample' => 'eval(...)',
          'line-number' => '42',
          'column-number' => '7',
        }
      end

      it 'normalizes every field onto the struct' do
        report = described_class.from_raw(raw)

        expect(report.document_uri).to eq('https://example.com/page')
        expect(report.referrer).to eq('https://example.com/')
        expect(report.blocked_uri).to eq('inline')
        expect(report.violated_directive).to eq('script-src')
        expect(report.effective_directive).to eq('script-src-elem')
        expect(report.original_policy).to eq("default-src 'self'")
        expect(report.disposition).to eq('report')
        expect(report.source_file).to eq('https://example.com/app.js')
        expect(report.script_sample).to eq('eval(...)')
      end

      it 'coerces numeric fields to Integers' do
        report = described_class.from_raw(raw)

        expect(report.status_code).to eq(200)
        expect(report.line_number).to eq(42)
        expect(report.column_number).to eq(7)
      end
    end

    context 'with a Reporting API (camelCase) report body' do
      let(:raw) do
        {
          'documentURL' => 'https://example.com/page',
          'blockedURL' => 'https://cdn.evil/x',
          'effectiveDirective' => 'img-src',
          'originalPolicy' => "default-src 'self'",
          'disposition' => 'enforce',
          'sourceFile' => 'https://example.com/app.js',
          'statusCode' => 200,
          'sample' => 'data',
          'lineNumber' => 10,
          'columnNumber' => 3,
        }
      end

      it 'normalizes camelCase fields onto the same struct shape' do
        report = described_class.from_raw(raw)

        expect(report.document_uri).to eq('https://example.com/page')
        expect(report.blocked_uri).to eq('https://cdn.evil/x')
        expect(report.effective_directive).to eq('img-src')
        expect(report.source_file).to eq('https://example.com/app.js')
        expect(report.script_sample).to eq('data')
        expect(report.line_number).to eq(10)
        expect(report.column_number).to eq(3)
        expect(report.status_code).to eq(200)
      end
    end

    describe 'directive cross-filling' do
      it 'fills violated_directive from effective_directive when only the latter is present' do
        report = described_class.from_raw('effectiveDirective' => 'img-src')

        expect(report.effective_directive).to eq('img-src')
        expect(report.violated_directive).to eq('img-src')
      end

      it 'fills effective_directive from violated_directive when only the former is present' do
        report = described_class.from_raw('violated-directive' => 'script-src')

        expect(report.violated_directive).to eq('script-src')
        expect(report.effective_directive).to eq('script-src')
      end

      it 'leaves both nil when neither directive is present' do
        report = described_class.from_raw('blocked-uri' => 'inline')

        expect(report.violated_directive).to be_nil
        expect(report.effective_directive).to be_nil
      end
    end

    describe 'numeric coercion edge cases' do
      it 'returns nil for a non-numeric value' do
        expect(described_class.from_raw('line-number' => 'abc').line_number).to be_nil
      end

      it 'returns nil for an absurdly long numeric string (defensive cap)' do
        expect(described_class.from_raw('line-number' => '1' * 40).line_number).to be_nil
      end

      it 'passes an Integer through unchanged' do
        expect(described_class.from_raw('lineNumber' => 99).line_number).to eq(99)
      end
    end

    it 'returns nil for non-Hash input' do
      expect(described_class.from_raw(nil)).to be_nil
      expect(described_class.from_raw('a string')).to be_nil
      expect(described_class.from_raw([])).to be_nil
    end
  end

  describe '#to_h' do
    it 'serializes to a symbol-keyed hash with a stable schema' do
      report = described_class.from_raw('violated-directive' => 'script-src', 'blocked-uri' => 'inline')

      hash = report.to_h
      expect(hash).to be_a(Hash)
      expect(hash[:violated_directive]).to eq('script-src')
      expect(hash[:blocked_uri]).to eq('inline')
      # Absent fields are present as nil (stable schema for consumers).
      expect(hash).to have_key(:source_file)
      expect(hash[:source_file]).to be_nil
    end
  end
end
