# spec/otto/locale_config_spec.rb

require 'spec_helper'

RSpec.describe Otto, 'locale configuration' do
  let(:available_locales) { { 'en' => 'English', 'es' => 'Spanish', 'fr' => 'French' } }
  let(:default_locale) { 'en' }

  describe 'initialization with direct locale options' do
    it 'configures locale from direct options' do
      otto = Otto.new(nil, {
                        available_locales: available_locales,
        default_locale: default_locale,
                      })

      expect(otto.locale_config.to_h).to eq({
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

      expect(otto.locale_config.to_h).to eq({
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

      expect(otto.locale_config.to_h).to eq({
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

      expect(otto.locale_config.to_h).to eq({
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


  describe "#determine_locale" do
    let(:test_routes) do
      [
        "GET / TestApp.index",
        "GET /show/:id TestApp.show",
        "POST /create TestApp.create",
      ]
    end

    let(:routes_file) { create_test_routes_file("common_routes.txt", test_routes) }
    subject(:otto) { described_class.new(routes_file) }

    it "parses Accept-Language header" do
      env = { "HTTP_ACCEPT_LANGUAGE" => "en-US,en;q=0.9,fr;q=0.8" }
      locales = otto.determine_locale(env)

      expect(locales).to be_an(Array)
      expect(locales.first).to eq("en-US")

      puts "=== DEBUG: Locale Determination ==="
      puts "Header: #{env["HTTP_ACCEPT_LANGUAGE"]}"
      puts "Parsed locales: #{locales.join(", ")}"
      puts "================================
"
    end

    it "handles missing Accept-Language header" do
      env = {}
      locales = otto.determine_locale(env)
      expect(locales).to eq(["en"])  # Uses default locale option
    end

    it "uses default locale when header is empty" do
      env = { "HTTP_ACCEPT_LANGUAGE" => "" }
      locales = otto.determine_locale(env)
      expect(locales).to eq(["en"])  # Uses default locale option
    end
  end

end
