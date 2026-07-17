# spec/otto/user_agent_privacy_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Privacy::UserAgentPrivacy do
  describe '.anonymize' do
    it 'strips a two-part version (dot-separated)' do
      expect(described_class.anonymize('Safari/537.36')).to eq('Safari/*.*')
    end

    it 'strips three- and four-part versions, longest first' do
      expect(described_class.anonymize('Chrome/119.0.0.0')).to eq('Chrome/*.*.*.*')
      expect(described_class.anonymize('Chrome/57.0.2987')).to eq('Chrome/*.*.*')
    end

    it 'strips underscore-separated versions (e.g. macOS 10_15_7)' do
      ua = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)'
      expect(described_class.anonymize(ua)).to eq('Mozilla/*.* (Macintosh; Intel Mac OS X *.*.*)')
    end

    it 'strips build identifiers' do
      ua = 'Mozilla/5.0 (Linux; Android 5.0; Nexus 5 Build/MRA58N) Chrome/141.0.0.0'
      out = described_class.anonymize(ua)
      expect(out).to include('Build/*')
      expect(out).not_to include('MRA58N')
    end

    it 'strips build identifiers that contain their own version-like tokens' do
      # Build/MPJ24.139-64 must be caught as a build id; this only works because
      # build stripping runs BEFORE version stripping.
      ua = 'Mozilla/5.0 (Linux; Android 6.0.1; Moto G (4) Build/MPJ24.139-64) Chrome/51.0.2704.81'
      out = described_class.anonymize(ua)
      expect(out).to include('Build/*')
      expect(out).not_to include('MPJ24.139-64')
      expect(out).not_to include('MPJ')
    end

    it 'preserves browser/OS family text (a partial, not a redaction)' do
      ua  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/119.0.0.0 Safari/537.36'
      out = described_class.anonymize(ua)
      expect(out).to include('Windows NT')
      expect(out).to include('Chrome')
      expect(out).to include('Safari')
      expect(out).not_to include('119.0.0.0')
    end

    it 'is idempotent (re-anonymizing already-anonymized output is a no-op)' do
      ua    = 'Mozilla/5.0 (Windows NT 10.0) Chrome/119.0.0.0 Safari/537.36'
      once  = described_class.anonymize(ua)
      twice = described_class.anonymize(once)
      expect(twice).to eq(once)
    end

    it 'truncates to DEFAULT_MAX_LENGTH' do
      long = "Agent/#{'x' * 1000}"
      expect(described_class.anonymize(long).length).to eq(described_class::DEFAULT_MAX_LENGTH)
    end

    it 'honors a custom max_length' do
      long = "Agent/#{'x' * 1000}"
      expect(described_class.anonymize(long, max_length: 50).length).to eq(50)
    end

    it 'returns nil for nil or empty input' do
      expect(described_class.anonymize(nil)).to be_nil
      expect(described_class.anonymize('')).to be_nil
    end
  end

  # The reason this surface exists: RedactedFingerprint must stay a thin
  # delegator so there is one source of truth for UA reduction. Pin that the
  # fingerprint's anonymized_ua equals the public method's output for the same
  # UA, so the two can never drift.
  describe 'RedactedFingerprint delegation' do
    it 'produces byte-identical output to the public surface' do
      ua     = 'Mozilla/5.0 (Linux; Android 9; Pixel 3 Build/PD1A.180720.030) Chrome/69.0.3497.100 Mobile Safari/537.36'
      config = Otto::Privacy::Config.new(geo_enabled: false)
      env    = { 'REMOTE_ADDR' => '203.0.113.42', 'HTTP_USER_AGENT' => ua }

      fingerprint = Otto::Privacy::RedactedFingerprint.new(env, config)
      expect(fingerprint.anonymized_ua).to eq(described_class.anonymize(ua))
    end
  end
end
