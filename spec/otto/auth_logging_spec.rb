# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe 'Otto Authentication and Security Logging' do
  let(:logger_double) { double('logger', debug: nil, info: nil, warn: nil, error: nil) }

  before do
    Otto.debug = true  # Enable debug logging for tests
    Otto.logger = logger_double
    allow(Otto.logger).to receive(:method).and_return(double(arity: 2))
  end

  after do
    Otto.debug = false
    Otto.logger = Logger.new($stdout)
  end

  describe 'Authentication logging via Otto.structured_log' do
    it 'logs authentication strategy execution start' do
      expect(logger_double).to receive(:debug).with('Auth strategy executing', hash_including(
        strategy: 'session',
        requirement: 'authenticated',
        ip: '127.0.0.1'
      ))

      Otto.structured_log(:debug, 'Auth strategy executing', {
        strategy: 'session',
        requirement: 'authenticated',
        ip: '127.0.0.1'
      })
    end

    it 'logs successful authentication' do
      expect(logger_double).to receive(:info).with('Auth strategy result', hash_including(
        strategy: 'session',
        success: true,
        user_id: 'user123'
      ))

      Otto.structured_log(:info, 'Auth strategy result', {
        strategy: 'session',
        success: true,
        user_id: 'user123',
        duration: 15200
      })
    end

    it 'logs failed authentication' do
      expect(logger_double).to receive(:info).with('Auth strategy result', hash_including(
        strategy: 'api_key',
        success: false,
        failure_reason: 'Invalid API key'
      ))

      Otto.structured_log(:info, 'Auth strategy result', {
        strategy: 'api_key',
        success: false,
        failure_reason: 'Invalid API key',
        duration: 8100
      })
    end
  end

  describe 'Security event logging via Otto.structured_log' do
    it 'logs CSRF validation failures' do
      expect(logger_double).to receive(:warn).with('CSRF validation failed', hash_including(
        method: 'POST',
        path: '/api/transfer',
        ip: '203.0.113.0'
      ))

      Otto.structured_log(:warn, 'CSRF validation failed', {
        method: 'POST',
        path: '/api/transfer',
        ip: '203.0.113.0',
        referrer: 'https://evil-site.com'
      })
    end

    it 'logs input validation failures' do
      expect(logger_double).to receive(:warn).with('Input validation failed', hash_including(
        method: 'POST',
        path: '/api/upload',
        error: 'Parameter depth exceeds maximum (10)'
      ))

      Otto.structured_log(:warn, 'Input validation failed', {
        method: 'POST',
        path: '/api/upload',
        ip: '203.0.113.0',
        error: 'Parameter depth exceeds maximum (10)'
      })
    end
  end
end
