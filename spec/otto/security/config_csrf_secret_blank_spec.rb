# spec/otto/security/config_csrf_secret_blank_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# A blank or nil CSRF secret must never become the HMAC signing key. Both the
# OTTO_CSRF_SECRET constructor path and Config#csrf_secret= fall back to a
# non-blank OTTO_CSRF_SECRET, then to a generated per-process secret, which
# keeps the production guard armed.
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

    {
      'a no-break space' => "\u00A0",
      'an ideographic space' => "\u3000",
      'a line separator' => "\u2028",
      'zero-width spaces and joiners' => "\u200B\u200C\u200D",
      'a word joiner' => "\u2060",
      'a byte order mark' => "\uFEFF",
      'NUL bytes' => "\0" * 32,
      'mixed ASCII and Unicode blanks' => " \t\u200B\u00A0\uFEFF\n",
      'UTF-16LE spaces' => '  '.encode(Encoding::UTF_16LE),
    }.each do |label, value|
      it "treats #{label} as blank and generates a secret" do
        config.csrf_secret = value

        expect(generated?(config)).to be true
        forged = "ab:#{OpenSSL::HMAC.hexdigest('SHA256', value, 'sess1:ab')}"
        expect(config.verify_csrf_token(forged, 'sess1')).to be false
      end
    end

    it 'keeps a secret that has invisible characters around visible ones' do
      secret = "\u200B#{'v' * 32}\uFEFF"
      config.csrf_secret = secret

      expect(generated?(config)).to be false
      expect(secret_of(config)).to eq(secret)
    end
  end

  describe '#csrf_secret= with OTTO_CSRF_SECRET set' do
    let(:env_secret) { 'e' * 64 }

    blank_values.merge('a zero-width space' => "\u200B").each do |label, value|
      it "falls back to OTTO_CSRF_SECRET for #{label}" do
        ENV['OTTO_CSRF_SECRET'] = env_secret
        cfg = described_class.new
        cfg.csrf_secret = 'c' * 64

        cfg.csrf_secret = value

        expect(generated?(cfg)).to be false
        expect(secret_of(cfg)).to eq(env_secret)
      end
    end

    it 'generates a secret when OTTO_CSRF_SECRET is blank too' do
      ENV['OTTO_CSRF_SECRET'] = " \u200B "
      cfg = described_class.new
      cfg.csrf_secret = 'c' * 64

      cfg.csrf_secret = nil

      expect(generated?(cfg)).to be true
      expect(secret_of(cfg)).not_to eq('c' * 64)
    end
  end

  describe 'a configured secret shorter than 32 bytes' do
    let(:short_warning) { /configured CSRF secret is shorter than 32 bytes/ }
    let(:messages) { [] }

    before do
      allow(Otto.logger).to receive(:warn) { |message| messages << message }
    end

    it 'is accepted with a warning that gives its length but not its value' do
      config.csrf_secret = 's' * 31

      expect(generated?(config)).to be false
      expect(messages.grep(short_warning)).to eq([messages.first])
      expect(messages.first).to include('(31 bytes)')
      expect(messages.join).not_to include('s' * 31)
    end

    it 'counts bytes, not characters' do
      config.csrf_secret = 'é' * 15 # 30 bytes
      config.csrf_secret = 'é' * 16 # 32 bytes

      expect(messages.grep(short_warning).size).to eq(1)
      expect(messages.first).to include('(30 bytes)')
    end

    it 'is not warned about at 32 bytes or for a generated secret' do
      config.csrf_secret = 'x' * 32
      config.csrf_secret = nil

      expect(messages.grep(short_warning)).to be_empty
    end

    it 'is warned about when it comes from OTTO_CSRF_SECRET' do
      ENV['OTTO_CSRF_SECRET'] = 'short'
      cfg = described_class.new

      expect(generated?(cfg)).to be false
      expect(messages.grep(short_warning).size).to eq(1)
    end

    it 'does not stop a production config from freezing' do
      ENV['RACK_ENV'] = 'production'
      config.csrf_secret = 's' * 16

      expect { config.deep_freeze! }.not_to raise_error
      expect(messages.grep(short_warning).size).to eq(1)
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
