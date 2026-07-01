# spec/otto/security/csp_config_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Security::Config, 'CSP reporting' do
  subject(:config) { described_class.new }

  describe 'defaults' do
    it 'has no report URI or callback configured' do
      expect(config.csp_report_uri).to be_nil
      expect(config.csp_violation_callback).to be_nil
    end
  end

  describe '#csp_report_uri=' do
    it 'stores a stripped path' do
      config.csp_report_uri = '  /_/csp-report  '
      expect(config.csp_report_uri).to eq('/_/csp-report')
    end

    it 'treats a blank string as not configured (nil)' do
      config.csp_report_uri = '   '
      expect(config.csp_report_uri).to be_nil
    end

    it 'clears the report URI when set to nil' do
      config.csp_report_uri = '/r'
      config.csp_report_uri = nil
      expect(config.csp_report_uri).to be_nil
    end

    it 'raises when the configuration is frozen' do
      config.deep_freeze!
      expect { config.csp_report_uri = '/r' }.to raise_error(FrozenError)
    end
  end

  describe '#generate_nonce_csp report-uri appending' do
    before { config.enable_csp_with_nonce! }

    it 'is byte-identical to the historical output when no report URI is set' do
      expect(config.generate_nonce_csp('N')).not_to include('report-uri')
      expect(config.generate_nonce_csp('N')).to end_with("worker-src 'self' data:;")
    end

    it 'appends a report-uri directive when a report URI is set' do
      config.csp_report_uri = '/_/csp-report'
      expect(config.generate_nonce_csp('N')).to include('report-uri /_/csp-report;')
    end

    it 'appends the directive in development mode too' do
      config.csp_report_uri = '/_/csp-report'
      expect(config.generate_nonce_csp('N', development_mode: true)).to include('report-uri /_/csp-report;')
    end
  end

  describe '#enable_csp! report-uri appending' do
    it 'is byte-identical to the bare policy when no report URI is set' do
      config.enable_csp!
      expect(config.security_headers['content-security-policy']).to eq("default-src 'self'")
    end

    it 'appends report-uri when the report URI is set BEFORE enable_csp!' do
      config.csp_report_uri = '/r'
      config.enable_csp!
      expect(config.security_headers['content-security-policy']).to eq("default-src 'self'; report-uri /r")
    end

    it 'appends report-uri when the report URI is set AFTER enable_csp! (order-independent)' do
      config.enable_csp!("default-src 'self'; script-src 'self'")
      config.csp_report_uri = '/r'
      expect(config.security_headers['content-security-policy'])
        .to eq("default-src 'self'; script-src 'self'; report-uri /r")
    end

    it 'does not fabricate a static policy when only the report URI is set' do
      config.csp_report_uri = '/r'
      expect(config.security_headers).not_to have_key('content-security-policy')
    end
  end

  describe '#csp_report_to_url= (modern Reporting API)' do
    let(:endpoint) { 'https://example.com/_/csp-report' }

    it 'defaults to nil with no Reporting-Endpoints header' do
      expect(config.csp_report_to_url).to be_nil
      expect(config.security_headers).not_to have_key('reporting-endpoints')
    end

    it 'stores a stripped absolute URL and emits the Reporting-Endpoints header' do
      config.csp_report_to_url = "  #{endpoint}  "
      expect(config.csp_report_to_url).to eq(endpoint)
      expect(config.security_headers['reporting-endpoints']).to eq(%(otto-csp="#{endpoint}"))
    end

    it 'treats a blank string as not configured (nil)' do
      config.csp_report_to_url = '   '
      expect(config.csp_report_to_url).to be_nil
      expect(config.security_headers).not_to have_key('reporting-endpoints')
    end

    it 'clears the URL and removes the header when set to nil' do
      config.csp_report_to_url = endpoint
      config.csp_report_to_url = nil
      expect(config.csp_report_to_url).to be_nil
      expect(config.security_headers).not_to have_key('reporting-endpoints')
    end

    it 'raises when the configuration is frozen' do
      config.deep_freeze!
      expect { config.csp_report_to_url = endpoint }.to raise_error(FrozenError)
    end

    it 'appends a report-to directive to the static policy (order-independent)' do
      config.csp_report_to_url = endpoint
      config.enable_csp!("default-src 'self'")
      expect(config.security_headers['content-security-policy'])
        .to eq("default-src 'self'; report-to otto-csp")
    end

    it 'emits both report-uri and report-to when both are configured' do
      config.enable_csp!("default-src 'self'")
      config.csp_report_uri = '/_/csp-report'
      config.csp_report_to_url = endpoint
      expect(config.security_headers['content-security-policy'])
        .to eq("default-src 'self'; report-uri /_/csp-report; report-to otto-csp")
    end

    it 'appends report-to to the nonce policy' do
      config.enable_csp_with_nonce!
      config.csp_report_to_url = endpoint
      expect(config.generate_nonce_csp('N')).to include('report-to otto-csp;')
    end

    it 'is byte-identical to historical output when no reporting endpoint is set' do
      config.enable_csp_with_nonce!
      expect(config.generate_nonce_csp('N')).not_to include('report-to')
    end
  end

  describe '#on_csp_violation / #dispatch_csp_violation' do
    let(:report) { Otto::Security::CSP::Report.from_raw('violated-directive' => 'script-src') }

    it 'invokes the registered callback with the report' do
      seen = []
      config.on_csp_violation { |r| seen << r }
      config.dispatch_csp_violation(report)

      expect(seen).to eq([report])
    end

    it 'replaces the callback on a second registration (last wins)' do
      seen = []
      config.on_csp_violation { |_r| seen << :first }
      config.on_csp_violation { |_r| seen << :second }
      config.dispatch_csp_violation(report)

      expect(seen).to eq([:second])
    end

    it 'does nothing (no error) when no callback is registered' do
      expect { config.dispatch_csp_violation(report) }.not_to raise_error
    end

    it 'isolates a throwing callback so dispatch never raises' do
      config.on_csp_violation { |_r| raise 'boom' }
      expect { config.dispatch_csp_violation(report) }.not_to raise_error
    end

    it 'raises when registering a callback on a frozen configuration' do
      config.deep_freeze!
      expect { config.on_csp_violation { |_r| :noop } }.to raise_error(FrozenError)
    end
  end

  describe 'freezing with a registered callback' do
    it 'deep-freezes cleanly and the callback remains invokable' do
      seen = []
      config.on_csp_violation { |r| seen << r }
      expect { config.deep_freeze! }.not_to raise_error

      report = Otto::Security::CSP::Report.from_raw('violated-directive' => 'img-src')
      config.dispatch_csp_violation(report)
      expect(seen).to eq([report])
    end
  end
end
