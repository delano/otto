# spec/otto/security/csp/nonce_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Security::CSP, '.nonce (framework-owned lazy nonce)' do
  describe '.nonce' do
    it 'generates a nonce on first access' do
      env = {}
      expect(described_class.nonce(env)).to be_a(String)
      expect(described_class.nonce(env)).not_to be_empty
    end

    it 'memoizes: the same value on repeated access within a request' do
      env = {}
      first = described_class.nonce(env)
      expect(described_class.nonce(env)).to eq(first)
      expect(env['otto.nonce']).to eq(first)
    end

    it 'stores the nonce under the default env key' do
      env = {}
      nonce = described_class.nonce(env)
      expect(env['otto.nonce']).to eq(nonce)
    end

    it 'honors a value already present under the key (app-minted convention)' do
      env = { 'otto.nonce' => 'preset' }
      expect(described_class.nonce(env)).to eq('preset')
    end

    it 'regenerates over a blank pre-set value' do
      env = { 'otto.nonce' => '' }
      expect(described_class.nonce(env)).not_to be_empty
    end

    it 'respects an explicit key override' do
      env = {}
      nonce = described_class.nonce(env, key: 'custom.nonce')
      expect(env['custom.nonce']).to eq(nonce)
      expect(env).not_to have_key('otto.nonce')
    end

    it 'resolves the key from the security config convention' do
      config = Otto::Security::Config.new
      config.csp_nonce_key = 'onetime.nonce'
      env = { 'otto.security_config' => config }

      nonce = described_class.nonce(env)
      expect(env['onetime.nonce']).to eq(nonce)
      expect(env).not_to have_key('otto.nonce')
    end
  end

  describe '.nonce? (emit-if-consumed predicate)' do
    it 'is false for an untouched request and does NOT mint a nonce' do
      env = {}
      expect(described_class.nonce?(env)).to be false
      expect(env).not_to have_key('otto.nonce')
    end

    it 'is true once a nonce has been consumed' do
      env = {}
      described_class.nonce(env)
      expect(described_class.nonce?(env)).to be true
    end

    it 'is false for a blank value under the key' do
      expect(described_class.nonce?({ 'otto.nonce' => '' })).to be false
    end

    it 'honors the configured key' do
      config = Otto::Security::Config.new
      config.csp_nonce_key = 'onetime.nonce'
      env = { 'otto.security_config' => config, 'onetime.nonce' => 'N' }
      expect(described_class.nonce?(env)).to be true
    end
  end

  describe 'Otto::Request#csp_nonce' do
    it 'generates and memoizes into the request env' do
      req = Otto::Request.new(mock_rack_env(method: 'GET', path: '/'))
      nonce = req.csp_nonce
      expect(nonce).to be_a(String)
      expect(nonce).not_to be_empty
      expect(req.csp_nonce).to eq(nonce)
      expect(req.env['otto.nonce']).to eq(nonce)
    end

    it 'uses the configured nonce key' do
      config = Otto::Security::Config.new
      config.csp_nonce_key = 'onetime.nonce'
      env = mock_rack_env(method: 'GET', path: '/')
      env['otto.security_config'] = config

      req = Otto::Request.new(env)
      nonce = req.csp_nonce
      expect(env['onetime.nonce']).to eq(nonce)
    end
  end

  describe 'Otto::Security::Config#csp_nonce_key' do
    subject(:config) { Otto::Security::Config.new }

    it 'defaults to otto.nonce' do
      expect(config.csp_nonce_key).to eq('otto.nonce')
    end

    it 'is settable to an app convention' do
      config.csp_nonce_key = 'onetime.nonce'
      expect(config.csp_nonce_key).to eq('onetime.nonce')
    end

    it 'strips surrounding whitespace' do
      config.csp_nonce_key = '  app.nonce  '
      expect(config.csp_nonce_key).to eq('app.nonce')
    end

    it 'resets a blank value to the default' do
      config.csp_nonce_key = '   '
      expect(config.csp_nonce_key).to eq('otto.nonce')
    end

    it 'raises when the configuration is frozen' do
      config.deep_freeze!
      expect { config.csp_nonce_key = 'x' }.to raise_error(FrozenError)
    end
  end
end
