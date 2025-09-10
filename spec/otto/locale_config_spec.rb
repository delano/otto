# spec/otto/locale_config_spec.rb

require 'spec_helper'

RSpec.describe Otto, 'locale configuration' do
  let(:available_locales) { { 'en' => 'English', 'es' => 'Spanish', 'fr' => 'French' } }
  let(:default_locale) { 'en' }

  describe 'global configuration' do
    after do
      # Reset global config after each test
      Otto.instance_variable_set(:@global_config, {})
    end

    it 'configures locale globally for all instances' do
      Otto.configure do |opts|
        opts.available_locales = available_locales
        opts.default_locale = default_locale
      end

      otto1 = Otto.new
      otto2 = Otto.new

      expect(otto1.locale_config).to eq({
                                          available_locales: available_locales,
        default_locale: default_locale,
                                        })
      expect(otto2.locale_config).to eq({
                                          available_locales: available_locales,
        default_locale: default_locale,
                                        })
    end

    it 'allows instance options to override global config' do
      Otto.configure do |opts|
        opts.available_locales = { 'en' => 'English' }
        opts.default_locale = 'en'
      end

      otto = Otto.new(nil, {
                        available_locales: available_locales,
        default_locale: 'es',
                      })

      expect(otto.locale_config).to eq({
                                         available_locales: available_locales,
        default_locale: 'es',
                                       })
    end
  end

  describe 'initialization with direct locale options' do
    it 'configures locale from direct options' do
      otto = Otto.new(nil, {
                        available_locales: available_locales,
        default_locale: default_locale,
                      })

      expect(otto.locale_config).to eq({
                                         available_locales: available_locales,
        default_locale: default_locale,
                                       })
    end
  end

  describe 'initialization with locale_config option' do
    it 'configures locale from initialization options' do
      otto = Otto.new(nil, {
                        locale_config: {
                          available_locales: available_locales,
                          default_locale: default_locale,
                        },
                      })

      expect(otto.locale_config).to eq({
                                         available_locales: available_locales,
        default_locale: default_locale,
                                       })
    end

    it 'supports abbreviated key names in config' do
      otto = Otto.new(nil, {
                        locale_config: {
                          available: available_locales,
                          default: default_locale,
                        },
                      })

      expect(otto.locale_config).to eq({
                                         available_locales: available_locales,
        default_locale: default_locale,
                                       })
    end

    it 'starts with no locale config when not provided' do
      otto = Otto.new

      expect(otto.locale_config).to be_nil
    end
  end

  describe '#configure' do
    let(:otto) { Otto.new }

    it 'configures locale settings' do
      otto.configure(
        available_locales: available_locales,
        default_locale: default_locale
      )

      expect(otto.locale_config).to eq({
                                         available_locales: available_locales,
        default_locale: default_locale,
                                       })
    end
  end

  describe 'request integration' do
    let(:app) do
      Class.new(Otto) do
        def initialize
          super(nil, {
            locale_config: {
              available_locales: { 'en' => 'English', 'es' => 'Spanish' },
              default_locale: 'en',
            },
          })
        end
      end.new
    end

    let(:test_env) do
      {
        'REQUEST_METHOD' => 'GET',
        'PATH_INFO' => '/test',
        'QUERY_STRING' => 'locale=es',
        'HTTP_HOST' => 'example.com',
        'SERVER_NAME' => 'example.com',
        'SERVER_PORT' => '80',
        'rack.request.query_hash' => { 'locale' => 'es' },
      }
    end

    it 'makes locale config available in request environment' do
      # Simulate a request to trigger handle_request
      begin
        app.call(test_env)
      rescue StandardError
        # We expect this to fail since there are no routes, but we just need
        # the environment to be processed
      end

      expect(test_env['otto.locale_config']).to eq({
                                                     available_locales: { 'en' => 'English', 'es' => 'Spanish' },
        default_locale: 'en',
                                                   })
    end
  end
end
