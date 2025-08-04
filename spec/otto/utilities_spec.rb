# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto, 'utility methods' do
  let(:test_routes) do
    [
      'GET / TestApp.index',
      'GET /show/:id TestApp.show',
      'POST /create TestApp.create'
    ]
  end

  let(:routes_file) { create_test_routes_file('test_util_routes.txt', test_routes) }
  subject(:otto) { described_class.new(routes_file) }

  describe '#determine_locale' do
    it 'parses Accept-Language header' do
      env = { 'HTTP_ACCEPT_LANGUAGE' => 'en-US,en;q=0.9,fr;q=0.8' }
      locales = otto.determine_locale(env)

      expect(locales).to be_an(Array)
      expect(locales.first).to eq('en-US')

      puts "\n=== DEBUG: Locale Determination ==="
      puts "Header: #{env['HTTP_ACCEPT_LANGUAGE']}"
      puts "Parsed locales: #{locales.join(', ')}"
      puts "================================\n"
    end

    it 'handles missing Accept-Language header' do
      env = {}
      locales = otto.determine_locale(env)
      expect(locales).to eq(['en'])  # Uses default locale option
    end

    it 'uses default locale when header is empty' do
      env = { 'HTTP_ACCEPT_LANGUAGE' => '' }
      locales = otto.determine_locale(env)
      expect(locales).to eq(['en'])  # Uses default locale option
    end
  end
end
