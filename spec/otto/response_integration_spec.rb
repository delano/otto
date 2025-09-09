# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto, 'response handler integration' do
  describe 'JSON response handling' do
    let(:app) { create_minimal_otto(['GET /api/data TestApp.json_data response=json']) }

    it 'automatically converts return value to JSON' do
      env = mock_rack_env(method: 'GET', path: '/api/data')
      response = app.call(env)

      expect(response[0]).to eq(200)
      expect(response[1]['Content-Type']).to eq('application/json')

      body = response[2].join
      parsed = JSON.parse(body)
      expect(parsed['message']).to eq('Hello JSON')
      expect(parsed['timestamp']).to be_a(Integer)
    end
  end

  describe 'redirect response handling' do
    let(:app) { create_minimal_otto(['GET /go TestApp.redirect_test response=redirect']) }

    it 'automatically redirects using return value' do
      env = mock_rack_env(method: 'GET', path: '/go')
      response = app.call(env)

      expect(response[0]).to eq(302)
      expect(response[1]['Location']).to eq('/redirected')
    end
  end

  describe 'view response handling' do
    let(:app) { create_minimal_otto(['GET /page TestApp.view_test response=view']) }

    it 'automatically sets HTML content type and body' do
      env = mock_rack_env(method: 'GET', path: '/page')
      response = app.call(env)

      expect(response[0]).to eq(200)
      expect(response[1]['Content-Type']).to eq('text/html')
      expect(response[2].join).to eq('<h1>View Test</h1>')
    end
  end

  describe 'auto response detection' do
    let(:app) { create_minimal_otto(['GET /auto TestApp.json_data response=auto']) }

    it 'automatically detects JSON response for hash return values' do
      env = mock_rack_env(method: 'GET', path: '/auto')
      response = app.call(env)

      expect(response[0]).to eq(200)
      expect(response[1]['Content-Type']).to eq('application/json')

      body = response[2].join
      parsed = JSON.parse(body)
      expect(parsed['message']).to eq('Hello JSON')
    end
  end

  describe 'default behavior preservation' do
    let(:app) { create_minimal_otto(['GET /normal TestApp.index']) }

    it 'preserves existing Otto behavior when no response type specified' do
      env = mock_rack_env(method: 'GET', path: '/normal')
      response = app.call(env)

      expect(response[0]).to eq(200)
      expect(response[2].join).to eq('Hello World')
      # Should not have JSON content type
      expect(response[1]['Content-Type']).to be_nil
    end
  end

  describe 'backward compatibility' do
    let(:app) do
      create_minimal_otto([
                            'GET /old TestApp.index',
                            'GET /new TestApp.json_data response=json',
                          ])
    end

    it 'allows mixing traditional and enhanced routes' do
      # Test traditional route
      env1 = mock_rack_env(method: 'GET', path: '/old')
      response1 = app.call(env1)
      expect(response1[2].join).to eq('Hello World')

      # Test enhanced route
      env2 = mock_rack_env(method: 'GET', path: '/new')
      response2 = app.call(env2)
      expect(response2[1]['Content-Type']).to eq('application/json')
    end
  end

  describe 'error handling' do
    let(:app) { create_minimal_otto(['GET /unknown TestApp.index response=unknown_type']) }

    it 'falls back to default handler for unknown response types' do
      # Should not raise an error and should work like default
      env = mock_rack_env(method: 'GET', path: '/unknown')

      expect { app.call(env) }.not_to raise_error

      response = app.call(env)
      expect(response[0]).to eq(200)
      expect(response[2].join).to eq('Hello World')
    end
  end
end
