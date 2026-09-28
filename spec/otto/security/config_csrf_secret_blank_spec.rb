# spec/otto/security/config_csrf_secret_blank_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# A blank or nil CSRF secret must never become the HMAC signing key. Both the
# OTTO_CSRF_SECRET constructor path and Config#csrf_secret= fall back to a
# generated per-process secret instead, which keeps the production guard armed.
RSpec.describe Otto::Security::Config do
  around do |example|
    original_rack_env = ENV.fetch('RACK_ENV', nil)
    original_secret = ENV.fetch('OTTO_CSRF_SECRET', nil)
    example.run
  ensure
    ENV['RACK_ENV'] = original_rack_env
    ENV['OTTO_CSRF_SECRET'] = original_secret
  end

  let(:config) do
    ENV.delete('OTTO_CSRF_SECRET')
    cfg = described_class.new
    cfg.enable_csrf_protection!
    cfg
  end

  def secret_of(cfg)
    cfg.instance_variable_get(:@csrf_secret)
  end

  def generated?(cfg)
    cfg.instance_variable_get(:@csrf_secret_generated)
  end

  blank_values = { 'an empty string' => '', 'a whitespace-only string' => '   ', 'nil' => nil }

  describe '#csrf_secret=' do
    blank_values.each do |label, value|
      context "with #{label}" do
        it 'replaces a configured secret with a fresh generated one' do
          configured = 'c' * 64
          config.csrf_secret = configured
          expect(generated?(config)).to be false

          config.csrf_secret = value

          expect(generated?(config)).to be true
          expect(secret_of(config)).to be_a(String)
          expect(secret_of(config).strip).not_to be_empty
          expect(secret_of(config)).not_to eq(configured)
        end

        it 'still round-trips generate/verify outside production' do
          config.csrf_secret = value
          token = config.generate_csrf_token('sess1')

          expect(config.verify_csrf_token(token, 'sess1')).to be true
        end

        it 'does not verify a token forged with the blank value as the HMAC key' do
          config.csrf_secret = value
          token_part = 'deadbeef'
          forged_key = value.to_s
          forged = "#{token_part}:#{OpenSSL::HMAC.hexdigest('SHA256', forged_key, "sess1:#{token_part}")}"

          expect(config.verify_csrf_token(forged, 'sess1')).to be false
        end

        it 'keeps the production guard armed for token generation' do
          ENV['RACK_ENV'] = 'production'
          config.csrf_secret = value

          expect { config.generate_csrf_token('sess1') }
            .to raise_error(ArgumentError, described_class::CSRF_SECRET_REQUIRED_MESSAGE)
        end
      end
    end

    [123, :secret, ['x' * 64], Object.new].each do |value|
      it "raises ArgumentError for a #{value.class} and keeps the previous secret" do
        config.csrf_secret = 'c' * 64
        token = config.generate_csrf_token('sess1')

        expect { config.csrf_secret = value }
          .to raise_error(ArgumentError, /CSRF secret must be a String or nil, got: #{value.class}/)
        expect(generated?(config)).to be false
        expect(config.verify_csrf_token(token, 'sess1')).to be true
      end
    end

    it 'stores a non-blank secret unchanged and marks it configured' do
      config.csrf_secret = ' padded secret '

      expect(generated?(config)).to be false
      expect(secret_of(config)).to eq(' padded secret ')
    end

    it 'accepts a non-blank secret that is not valid UTF-8' do
      secret = (+"\xff\xfe secret ").force_encoding(Encoding::UTF_8)

      expect { config.csrf_secret = secret }.not_to raise_error
      expect(generated?(config)).to be false
      expect(secret_of(config)).to eq(secret)
    end
  end

  describe '#initialize with OTTO_CSRF_SECRET' do
    ['', '   '].each do |value|
      it "treats #{value.inspect} as unset and generates a secret" do
        ENV['OTTO_CSRF_SECRET'] = value
        cfg = described_class.new

        expect(generated?(cfg)).to be true
        expect(secret_of(cfg).strip).not_to be_empty
      end
    end

    it 'uses a non-blank value as the configured secret' do
      ENV['OTTO_CSRF_SECRET'] = 'e' * 64
      cfg = described_class.new

      expect(generated?(cfg)).to be false
      expect(secret_of(cfg)).to eq('e' * 64)
    end
  end
end
