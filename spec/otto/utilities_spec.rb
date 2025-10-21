# frozen_string_literal: true
# spec/otto/utilities_spec.rb

require 'spec_helper'

RSpec.describe Otto, 'utility methods' do
  let(:test_routes) do
    [
      'GET / TestApp.index',
      'GET /show/:id TestApp.show',
      'POST /create TestApp.create',
    ]
  end

  let(:routes_file) { create_test_routes_file('common_routes.txt', test_routes) }
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

    describe Otto::Utils do
      describe '#now' do
        it 'returns current time in UTC' do
          freeze_time = Time.parse('2023-01-01 12:00:00 UTC')
          allow(Time).to receive(:now).and_return(freeze_time)

          result = Otto::Utils.now

          expect(result).to eq(freeze_time.utc)
          expect(result.zone).to eq('UTC')
        end
      end

      describe '#yes?' do
        it 'returns true for truthy string values' do
          expect(Otto::Utils.yes?('true')).to be true
          expect(Otto::Utils.yes?('TRUE')).to be true
          expect(Otto::Utils.yes?('yes')).to be true
          expect(Otto::Utils.yes?('YES')).to be true
          expect(Otto::Utils.yes?('1')).to be true
        end

        it 'returns false for falsy string values' do
          expect(Otto::Utils.yes?('false')).to be false
          expect(Otto::Utils.yes?('no')).to be false
          expect(Otto::Utils.yes?('0')).to be false
          expect(Otto::Utils.yes?('random')).to be false
        end

        it 'returns false for empty or nil values' do
          expect(Otto::Utils.yes?(nil)).to be false
          expect(Otto::Utils.yes?('')).to be false
          expect(Otto::Utils.yes?('   ')).to be false
        end

        it 'handles non-string values by converting to string' do
          expect(Otto::Utils.yes?(1)).to be true
          expect(Otto::Utils.yes?(0)).to be false
          expect(Otto::Utils.yes?(true)).to be true
          expect(Otto::Utils.yes?(false)).to be false
        end
      end
  end
end
