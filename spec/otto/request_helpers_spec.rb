require 'spec_helper'

RSpec.describe Otto::RequestHelpers do
  let(:app_class) do
    Class.new(Otto) do
      def initialize
        @routes = []
      end
    end
  end

  let(:request_env) do
    {
      'REQUEST_METHOD' => 'GET',
      'PATH_INFO' => '/test',
      'QUERY_STRING' => '',
      'HTTP_HOST' => 'example.com',
      'SERVER_NAME' => 'example.com',
      'SERVER_PORT' => '80',
      'rack.request.query_hash' => {}
    }
  end

  let(:request_object) do
    env_hash = request_env
    obj = Object.new
    obj.extend(Otto::RequestHelpers)
    obj.define_singleton_method(:env) { env_hash }
    obj
  end

  describe '#check_locale!' do
    let(:available_locales) { { 'en' => 'English', 'es' => 'Spanish', 'fr' => 'French' } }
    let(:default_locale) { 'en' }

    context 'with required configuration' do
      it 'returns default locale when no locale sources are present' do
        result = request_object.check_locale!(nil, {
          available_locales: available_locales,
          default_locale: default_locale
        })

        expect(result).to eq('en')
        expect(request_env['locale']).to eq('en')
      end

      it 'uses locale parameter when provided' do
        result = request_object.check_locale!('es', {
          available_locales: available_locales,
          default_locale: default_locale
        })

        expect(result).to eq('es')
        expect(request_env['locale']).to eq('es')
      end

      it 'uses query parameter when no locale parameter provided' do
        request_env['rack.request.query_hash'] = { 'locale' => 'fr' }

        result = request_object.check_locale!(nil, {
          available_locales: available_locales,
          default_locale: default_locale
        })

        expect(result).to eq('fr')
        expect(request_env['locale']).to eq('fr')
      end

      it 'uses user locale when no other sources available' do
        result = request_object.check_locale!(nil, {
          available_locales: available_locales,
          default_locale: default_locale,
          preferred_locale: 'es'
        })

        expect(result).to eq('es')
        expect(request_env['locale']).to eq('es')
      end

      it 'uses rack.locale when no other sources available' do
        request_env['rack.locale'] = ['fr', 'en']

        result = request_object.check_locale!(nil, {
          available_locales: available_locales,
          default_locale: default_locale
        })

        expect(result).to eq('fr')
        expect(request_env['locale']).to eq('fr')
      end

      it 'falls back to default when locale is not available' do
        result = request_object.check_locale!('de', {
          available_locales: available_locales,
          default_locale: default_locale
        })

        expect(result).to eq('en')
        expect(request_env['locale']).to eq('en')
      end

      it 'respects precedence order' do
        request_env['rack.request.query_hash'] = { 'locale' => 'fr' }
        request_env['rack.locale'] = ['es']

        result = request_object.check_locale!('en', {
          available_locales: available_locales,
          default_locale: default_locale,
          preferred_locale: 'es'
        })

        expect(result).to eq('en') # Parameter takes precedence
      end

      it 'uses custom locale environment key' do
        result = request_object.check_locale!('es', {
          available_locales: available_locales,
          default_locale: default_locale,
          locale_env_key: 'custom.locale'
        })

        expect(result).to eq('es')
        expect(request_env['custom.locale']).to eq('es')
        expect(request_env['locale']).to be_nil
      end
    end

    context 'with Otto-level configuration' do
      before do
        request_env['otto.locale_config'] = {
          available_locales: available_locales,
          default_locale: default_locale
        }
      end

      it 'uses Otto configuration when opts not provided' do
        result = request_object.check_locale!('es')

        expect(result).to eq('es')
        expect(request_env['locale']).to eq('es')
      end

      it 'allows opts to override Otto configuration' do
        result = request_object.check_locale!('fr', {
          available_locales: { 'fr' => 'French', 'de' => 'German' },
          default_locale: 'de'
        })

        expect(result).to eq('fr')
        expect(request_env['locale']).to eq('fr')
      end
    end

    context 'with environment fallback configuration' do
      before do
        request_env['otto.available_locales'] = available_locales
        request_env['otto.default_locale'] = default_locale
      end

      it 'uses configuration from environment when opts not provided' do
        result = request_object.check_locale!('es')

        expect(result).to eq('es')
        expect(request_env['locale']).to eq('es')
      end
    end

    context 'with debug logging enabled' do
      it 'logs debug information when Otto.logger is available' do
        logger = double('logger')
        allow(Otto).to receive(:logger).and_return(logger)
        stub_const('Otto', Otto)

        expect(logger).to receive(:debug).with(/\[check_locale!\]/)

        request_object.check_locale!('es', {
          available_locales: available_locales,
          default_locale: default_locale,
          debug: true
        })
      end
    end

    context 'error cases' do
      it 'raises ArgumentError when available_locales is missing' do
        expect {
          request_object.check_locale!(nil, {
            default_locale: default_locale
          })
        }.to raise_error(ArgumentError, 'available_locales and default_locale are required (provide via opts or Otto configuration)')
      end

      it 'raises ArgumentError when default_locale is missing' do
        expect {
          request_object.check_locale!(nil, {
            available_locales: available_locales
          })
        }.to raise_error(ArgumentError, 'available_locales and default_locale are required (provide via opts or Otto configuration)')
      end

      it 'raises ArgumentError when both are missing' do
        expect {
          request_object.check_locale!
        }.to raise_error(ArgumentError, 'available_locales and default_locale are required (provide via opts or Otto configuration)')
      end
    end
  end
end
