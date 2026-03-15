# spec/otto/locale/middleware_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Locale::Middleware do
  let(:inner_app) { ->(env) { [200, {}, [env['otto.locale']]] } }
  let(:default_locale) { 'en' }
  let(:available_locales) { { 'en' => 'English', 'es' => 'Spanish', 'fr' => 'French' } }
  let(:fallback_locale) { nil }

  let(:app) do
    described_class.new(inner_app,
      available_locales: available_locales,
      default_locale: default_locale,
      fallback_locale: fallback_locale)
  end

  # Returns the resolved locale string from env['otto.locale']
  def request_with_accept_language(header)
    env = Rack::MockRequest.env_for('/', 'HTTP_ACCEPT_LANGUAGE' => header)
    _status, _headers, body = app.call(env)
    body.first
  end

  # For requests with no Accept-Language header at all
  def request_without_accept_language
    env = Rack::MockRequest.env_for('/')
    _status, _headers, body = app.call(env)
    body.first
  end

  describe 'exact region match' do
    context 'when fr_FR is available and Accept-Language is fr-FR' do
      let(:available_locales) { { 'en' => 'English', 'fr_FR' => 'French (France)' } }

      it 'resolves to fr_FR' do
        expect(request_with_accept_language('fr-FR')).to eq('fr_FR')
      end
    end

    context 'when pt_BR is available and Accept-Language is pt-BR' do
      let(:available_locales) { { 'en' => 'English', 'pt_BR' => 'Portuguese (Brazil)' } }

      it 'resolves to pt_BR' do
        expect(request_with_accept_language('pt-BR')).to eq('pt_BR')
      end
    end

    context 'when both fr and fr_FR are available' do
      let(:available_locales) { { 'en' => 'English', 'fr' => 'French', 'fr_FR' => 'French (France)' } }

      it 'prefers exact region match fr_FR over primary code fr' do
        expect(request_with_accept_language('fr-FR')).to eq('fr_FR')
      end
    end
  end

  describe 'primary code fallback' do
    context 'when only fr is available and Accept-Language is fr-FR' do
      let(:available_locales) { { 'en' => 'English', 'fr' => 'French' } }

      it 'falls back to primary code fr' do
        expect(request_with_accept_language('fr-FR')).to eq('fr')
      end
    end

    context 'when only en is available and Accept-Language is en-US,en;q=0.9' do
      let(:available_locales) { { 'en' => 'English' } }

      it 'resolves to en via primary code' do
        expect(request_with_accept_language('en-US,en;q=0.9')).to eq('en')
      end
    end
  end

  describe 'fallback chain' do
    context 'when fallback_locale maps fr_FR to fr_CA first' do
      let(:available_locales) { { 'en' => 'English', 'fr_CA' => 'French (Canada)' } }
      let(:fallback_locale) { { 'fr_FR' => %w[fr_CA fr] } }

      it 'resolves to fr_CA through the fallback chain' do
        expect(request_with_accept_language('fr-FR')).to eq('fr_CA')
      end
    end

    context 'when fallback chain entries do not match available locales' do
      let(:available_locales) { { 'en' => 'English', 'fr' => 'French' } }
      let(:fallback_locale) { { 'fr_FR' => %w[fr_BE fr_CA] } }

      it 'falls through the chain to primary code match' do
        expect(request_with_accept_language('fr-FR')).to eq('fr')
      end
    end

    context 'when fallback_locale uses canonical key and header is lowercase' do
      let(:available_locales) { { 'en' => 'English', 'fr_CA' => 'French (Canada)' } }
      let(:fallback_locale) { { 'fr_FR' => %w[fr_CA fr] } }

      it 'finds the fallback chain via canonical form lookup' do
        # fr-fr normalizes to fr_fr, canonical form fr_FR matches the chain key
        expect(request_with_accept_language('fr-fr')).to eq('fr_CA')
      end
    end

    context 'when fallback chain and primary code both miss' do
      let(:available_locales) { { 'en' => 'English', 'de' => 'German' } }
      let(:fallback_locale) { { 'fr_FR' => %w[fr_CA fr_BE] } }

      it 'returns default locale' do
        expect(request_with_accept_language('fr-FR')).to eq('en')
      end
    end
  end

  describe 'q-value ordering with mixed entries' do
    context 'when de;q=0.7 and fr-FR;q=0.9 with both available' do
      let(:available_locales) { { 'en' => 'English', 'de' => 'German', 'fr_FR' => 'French (France)' } }

      it 'resolves to fr_FR (higher q-value)' do
        expect(request_with_accept_language('de;q=0.7,fr-FR;q=0.9')).to eq('fr_FR')
      end
    end

    context 'when en;q=0.5 and zh-TW;q=0.9 with zh_TW available' do
      let(:available_locales) { { 'en' => 'English', 'zh_TW' => 'Chinese (Traditional)' } }

      it 'resolves to zh_TW (higher q-value)' do
        expect(request_with_accept_language('en;q=0.5,zh-TW;q=0.9')).to eq('zh_TW')
      end
    end

    context 'when multiple tags have the same q-value' do
      let(:available_locales) { { 'en' => 'English', 'fr' => 'French', 'de' => 'German' } }

      it 'uses position as tiebreaker (first listed wins)' do
        # Both fr and de have q=0.9, fr appears first
        expect(request_with_accept_language('fr;q=0.9,de;q=0.9')).to eq('fr')
      end
    end
  end

  describe 'edge cases' do
    context 'when no locale in the header matches available locales' do
      let(:available_locales) { { 'en' => 'English' } }

      it 'returns default locale' do
        expect(request_with_accept_language('ja,ko;q=0.9')).to eq('en')
      end
    end

    context 'when Accept-Language header is missing' do
      let(:available_locales) { { 'en' => 'English', 'fr' => 'French' } }

      it 'returns default locale' do
        expect(request_without_accept_language).to eq('en')
      end
    end

    context 'when Accept-Language header is empty' do
      let(:available_locales) { { 'en' => 'English' } }

      it 'returns default locale' do
        expect(request_with_accept_language('')).to eq('en')
      end
    end

    context 'with malformed Accept-Language header' do
      let(:available_locales) { { 'en' => 'English' } }

      it 'handles garbage input without raising' do
        expect(request_with_accept_language(';;;,,,===!!!')).to eq('en')
      end

      it 'handles extremely long header values' do
        long_header = ('x,' * 1000).chomp(',')
        expect(request_with_accept_language(long_header)).to eq('en')
      end

      it 'handles q-values outside valid range' do
        expect(request_with_accept_language('en;q=2.0,fr;q=-1.0')).to eq('en')
      end
    end

    context 'with empty available_locales' do
      it 'raises ArgumentError on initialization' do
        expect do
          described_class.new(inner_app,
            available_locales: {},
            default_locale: 'en')
        end.to raise_error(ArgumentError, /cannot be empty/)
      end
    end

    context 'with non-Hash available_locales' do
      it 'raises ArgumentError on initialization' do
        expect do
          described_class.new(inner_app,
            available_locales: %w[en fr],
            default_locale: 'en')
        end.to raise_error(ArgumentError, /must be a Hash/)
      end
    end

    context 'when default_locale is not in available_locales' do
      it 'raises ArgumentError on initialization' do
        expect do
          described_class.new(inner_app,
            available_locales: { 'en' => 'English' },
            default_locale: 'de')
        end.to raise_error(ArgumentError, /must be in available_locales/)
      end
    end

    context 'with invalid fallback_locale type' do
      it 'raises ArgumentError when fallback_locale is not a Hash' do
        expect do
          described_class.new(inner_app,
            available_locales: { 'en' => 'English' },
            default_locale: 'en',
            fallback_locale: 'not_a_hash')
        end.to raise_error(ArgumentError, /must be a Hash/)
      end

      it 'raises ArgumentError when fallback_locale values are not Arrays' do
        expect do
          described_class.new(inner_app,
            available_locales: { 'en' => 'English' },
            default_locale: 'en',
            fallback_locale: { 'fr_FR' => 'fr' })
        end.to raise_error(ArgumentError, /must be Arrays/)
      end
    end

    context 'with case-insensitive matching and lowercase locale key (fr_fr)' do
      let(:available_locales) { { 'en' => 'English', 'fr_fr' => 'French (France)' } }

      it 'matches FR-fr to fr_fr' do
        expect(request_with_accept_language('FR-fr')).to eq('fr_fr')
      end

      it 'matches FR-FR to fr_fr' do
        expect(request_with_accept_language('FR-FR')).to eq('fr_fr')
      end
    end

    context 'with case-insensitive matching and mixed case locale key (fr_FR)' do
      let(:available_locales) { { 'en' => 'English', 'fr_FR' => 'French (France)' } }

      it 'matches fr-FR to fr_FR via exact normalization' do
        expect(request_with_accept_language('fr-FR')).to eq('fr_FR')
      end

      it 'matches FR-FR to fr_FR via BCP 47 canonical form' do
        # FR-FR normalizes to FR_FR (no match), downcases to fr_fr (no match),
        # then canonical form fr_FR matches.
        expect(request_with_accept_language('FR-FR')).to eq('fr_FR')
      end

      it 'matches Fr-fR to fr_FR via BCP 47 canonical form' do
        expect(request_with_accept_language('Fr-fR')).to eq('fr_FR')
      end
    end
  end

  describe 'backward compatibility' do
    context 'with primary-code-only locales' do
      let(:available_locales) { { 'en' => 'English', 'es' => 'Spanish', 'fr' => 'French' } }

      it 'matches Accept-Language: en' do
        expect(request_with_accept_language('en')).to eq('en')
      end

      it 'matches Accept-Language: es' do
        expect(request_with_accept_language('es')).to eq('es')
      end

      it 'matches Accept-Language: fr' do
        expect(request_with_accept_language('fr')).to eq('fr')
      end
    end

    context 'with standard q-value header' do
      let(:available_locales) { { 'en' => 'English', 'fr' => 'French' } }

      it 'parses en-US,en;q=0.9,fr;q=0.8 and resolves to en' do
        expect(request_with_accept_language('en-US,en;q=0.9,fr;q=0.8')).to eq('en')
      end

      it 'parses fr;q=0.9,en;q=0.5 and resolves to fr (higher q-value)' do
        expect(request_with_accept_language('fr;q=0.9,en;q=0.5')).to eq('fr')
      end
    end

    context 'with implicit q=1.0 for first entry' do
      let(:available_locales) { { 'en' => 'English', 'de' => 'German' } }

      it 'treats tag without q-value as q=1.0' do
        expect(request_with_accept_language('de,en;q=0.9')).to eq('de')
      end
    end
  end
end
