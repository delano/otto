# spec/otto/security/csp/policy_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Direct coverage for Otto::Security::CSP::Policy. Its output is also exercised
# transitively (Config#generate_nonce_csp / #build_static_csp delegate here), but
# pinning the exact directive format in isolation guards the byte-identical
# contract against a regression in the delegation or the directive sets.
RSpec.describe Otto::Security::CSP::Policy do
  let(:production) do
    "default-src 'none'; script-src 'nonce-N'; style-src 'self' 'unsafe-inline'; " \
      "connect-src 'self' wss: https:; img-src 'self' data:; font-src 'self'; " \
      "object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; " \
      "manifest-src 'self'; worker-src 'self' data:;"
  end

  describe '.nonce_policy' do
    it 'produces the production directive set by default' do
      expect(described_class.nonce_policy('N')).to eq(production)
    end

    it 'produces the development directive set when requested' do
      csp = described_class.nonce_policy('N', development_mode: true)
      expect(csp).to include("script-src 'nonce-N' 'unsafe-inline';")
      expect(csp).to include("connect-src 'self' ws: wss: http: https:;")
    end

    it 'appends report-uri (terminated with a semicolon) when configured' do
      expect(described_class.nonce_policy('N', report_uri: '/_/csp-report'))
        .to eq("#{production} report-uri /_/csp-report;")
    end

    it 'appends report-to (using the shared group) when a reporting URL is configured' do
      expect(described_class.nonce_policy('N', report_to_url: 'https://e/x'))
        .to eq("#{production} report-to otto-csp;")
    end

    it 'appends report-uri before report-to when both are configured' do
      expect(described_class.nonce_policy('N', report_uri: '/r', report_to_url: 'https://e/x'))
        .to eq("#{production} report-uri /r; report-to otto-csp;")
    end

    it 'omits reporting directives for nil/blank values' do
      expect(described_class.nonce_policy('N', report_uri: '', report_to_url: nil)).to eq(production)
    end
  end

  describe '.static_policy' do
    it 'is byte-identical to the base policy when no reporting is configured' do
      expect(described_class.static_policy("default-src 'self'")).to eq("default-src 'self'")
    end

    it 'appends report-uri joined with a semicolon' do
      expect(described_class.static_policy("default-src 'self'", report_uri: '/r'))
        .to eq("default-src 'self'; report-uri /r")
    end

    it 'appends report-to using the shared group' do
      expect(described_class.static_policy("default-src 'self'", report_to_url: 'https://e/x'))
        .to eq("default-src 'self'; report-to otto-csp")
    end

    it 'appends both, report-uri before report-to' do
      expect(described_class.static_policy("default-src 'self'", report_uri: '/r', report_to_url: 'https://e/x'))
        .to eq("default-src 'self'; report-uri /r; report-to otto-csp")
    end
  end

  describe 'reporting directive helpers' do
    it 'returns nil for a nil/blank report URI' do
      expect(described_class.report_uri_directive(nil)).to be_nil
      expect(described_class.report_uri_directive('')).to be_nil
    end

    it 'returns nil for a nil/blank report-to URL' do
      expect(described_class.report_to_directive(nil)).to be_nil
      expect(described_class.report_to_directive('')).to be_nil
    end
  end

  describe 'REPORTING_GROUP' do
    it 'is the shared group name' do
      expect(described_class::REPORTING_GROUP).to eq('otto-csp')
    end

    it 'is the single source Config::CSP_REPORTING_GROUP aliases' do
      expect(Otto::Security::Config::CSP_REPORTING_GROUP).to eq(described_class::REPORTING_GROUP)
    end
  end

  describe 'byte-identical delegation from Config' do
    it 'matches Config#generate_nonce_csp exactly (production + reporting)' do
      config = Otto::Security::Config.new
      config.enable_csp_with_nonce!
      config.csp_report_uri = '/_/csp-report'
      config.csp_report_to_url = 'https://example.com/_/csp-report'

      expect(config.generate_nonce_csp('N')).to eq(
        described_class.nonce_policy('N', report_uri: '/_/csp-report', report_to_url: 'https://example.com/_/csp-report')
      )
    end
  end
end
