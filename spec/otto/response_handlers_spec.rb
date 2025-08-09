# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::ResponseHandlers do
  describe Otto::ResponseHandlers::JSONHandler do
    let(:response) { Rack::Response.new }

    it 'sets JSON content type' do
      Otto::ResponseHandlers::JSONHandler.handle({message: 'test'}, response)

      expect(response['Content-Type']).to eq('application/json')
    end

    it 'serializes hash data to JSON' do
      data = { message: 'Hello', status: 'success' }
      Otto::ResponseHandlers::JSONHandler.handle(data, response)

      expect(response.body).to eq([JSON.generate(data)])
      expect(response.status).to eq(200)
    end

    it 'wraps non-hash data in success wrapper' do
      Otto::ResponseHandlers::JSONHandler.handle('test result', response)

      parsed = JSON.parse(response.body.join)
      expect(parsed).to eq({ 'success' => true, 'data' => 'test result' })
    end

    it 'handles nil result' do
      Otto::ResponseHandlers::JSONHandler.handle(nil, response)

      parsed = JSON.parse(response.body.join)
      expect(parsed).to eq({ 'success' => true })
    end

    it 'uses logic instance response_data when available' do
      logic_instance = double('LogicInstance')
      allow(logic_instance).to receive(:respond_to?).with(:response_data).and_return(true)
      allow(logic_instance).to receive(:response_data).and_return({ custom: 'data' })

      context = { logic_instance: logic_instance }
      Otto::ResponseHandlers::JSONHandler.handle('ignored', response, context)

      parsed = JSON.parse(response.body.join)
      expect(parsed).to eq({ 'custom' => 'data' })
    end
  end

  describe Otto::ResponseHandlers::RedirectHandler do
    let(:response) { Rack::Response.new }

    it 'redirects to default path when no context provided' do
      Otto::ResponseHandlers::RedirectHandler.handle(nil, response)

      expect(response.status).to eq(302)
      expect(response['Location']).to eq('/')
    end

    it 'redirects to result when result is a string' do
      Otto::ResponseHandlers::RedirectHandler.handle('/custom/path', response)

      expect(response['Location']).to eq('/custom/path')
    end

    it 'uses context redirect_path when provided' do
      context = { redirect_path: '/admin/dashboard' }
      Otto::ResponseHandlers::RedirectHandler.handle(nil, response, context)

      expect(response['Location']).to eq('/admin/dashboard')
    end

    it 'uses logic instance redirect_path when available' do
      logic_instance = double('LogicInstance')
      allow(logic_instance).to receive(:respond_to?).with(:redirect_path).and_return(true)
      allow(logic_instance).to receive(:redirect_path).and_return('/user/profile')

      context = { logic_instance: logic_instance }
      Otto::ResponseHandlers::RedirectHandler.handle(nil, response, context)

      expect(response['Location']).to eq('/user/profile')
    end
  end

  describe Otto::ResponseHandlers::ViewHandler do
    let(:response) { Rack::Response.new }

    it 'sets HTML content type by default' do
      Otto::ResponseHandlers::ViewHandler.handle('test content', response)

      expect(response['Content-Type']).to eq('text/html')
      expect(response.body).to eq(['test content'])
    end

    it 'preserves existing content type' do
      response['Content-Type'] = 'text/plain'
      Otto::ResponseHandlers::ViewHandler.handle('test content', response)

      expect(response['Content-Type']).to eq('text/plain')
    end

    it 'uses logic instance view when available' do
      view_double = double('View')
      allow(view_double).to receive(:render).and_return('<html>Rendered View</html>')

      logic_instance = double('LogicInstance')
      allow(logic_instance).to receive(:respond_to?).with(:view).and_return(true)
      allow(logic_instance).to receive(:view).and_return(view_double)

      context = { logic_instance: logic_instance }
      Otto::ResponseHandlers::ViewHandler.handle('ignored', response, context)

      expect(response.body).to eq(['<html>Rendered View</html>'])
    end

    it 'handles empty result gracefully' do
      Otto::ResponseHandlers::ViewHandler.handle(nil, response)

      expect(response.body).to eq([''])
    end
  end

  describe Otto::ResponseHandlers::HandlerFactory do
    describe '.create_handler' do
      it 'returns JSONHandler for json type' do
        handler = Otto::ResponseHandlers::HandlerFactory.create_handler('json')
        expect(handler).to eq(Otto::ResponseHandlers::JSONHandler)
      end

      it 'returns RedirectHandler for redirect type' do
        handler = Otto::ResponseHandlers::HandlerFactory.create_handler('redirect')
        expect(handler).to eq(Otto::ResponseHandlers::RedirectHandler)
      end

      it 'returns ViewHandler for view type' do
        handler = Otto::ResponseHandlers::HandlerFactory.create_handler('view')
        expect(handler).to eq(Otto::ResponseHandlers::ViewHandler)
      end

      it 'returns AutoHandler for auto type' do
        handler = Otto::ResponseHandlers::HandlerFactory.create_handler('auto')
        expect(handler).to eq(Otto::ResponseHandlers::AutoHandler)
      end

      it 'returns DefaultHandler for unknown types' do
        handler = Otto::ResponseHandlers::HandlerFactory.create_handler('unknown')
        expect(handler).to eq(Otto::ResponseHandlers::DefaultHandler)
      end

      it 'is case insensitive' do
        handler = Otto::ResponseHandlers::HandlerFactory.create_handler('JSON')
        expect(handler).to eq(Otto::ResponseHandlers::JSONHandler)
      end
    end

    describe '.handle_response' do
      let(:response) { Rack::Response.new }

      it 'delegates to the appropriate handler' do
        data = { message: 'test' }
        Otto::ResponseHandlers::HandlerFactory.handle_response(data, response, 'json')

        expect(response['Content-Type']).to eq('application/json')
        parsed = JSON.parse(response.body.join)
        expect(parsed).to eq({ 'message' => 'test' })
      end
    end
  end

  describe Otto::ResponseHandlers::AutoHandler do
    let(:response) { Rack::Response.new }

    it 'chooses JSONHandler for hash results' do
      allow(Otto::ResponseHandlers::JSONHandler).to receive(:handle)

      Otto::ResponseHandlers::AutoHandler.handle({data: 'test'}, response)

      expect(Otto::ResponseHandlers::JSONHandler).to have_received(:handle)
    end

    it 'chooses JSONHandler when response already has JSON content type' do
      response['Content-Type'] = 'application/json'
      allow(Otto::ResponseHandlers::JSONHandler).to receive(:handle)

      Otto::ResponseHandlers::AutoHandler.handle('test', response)

      expect(Otto::ResponseHandlers::JSONHandler).to have_received(:handle)
    end

    it 'chooses ViewHandler for logic instances with view capability' do
      logic_instance = double('LogicInstance')
      allow(logic_instance).to receive(:respond_to?).with(:view).and_return(true)
      allow(logic_instance).to receive(:respond_to?).with(:redirect_path).and_return(false)
      allow(logic_instance).to receive(:redirect_path).and_return(nil)
      allow(Otto::ResponseHandlers::ViewHandler).to receive(:handle)

      context = { logic_instance: logic_instance }
      Otto::ResponseHandlers::AutoHandler.handle('test', response, context)

      expect(Otto::ResponseHandlers::ViewHandler).to have_received(:handle)
    end

    it 'chooses DefaultHandler as fallback' do
      allow(Otto::ResponseHandlers::DefaultHandler).to receive(:handle)

      # Use context that doesn't match any other handler conditions
      context = { logic_instance: nil }
      Otto::ResponseHandlers::AutoHandler.handle('simple string', response, context)

      expect(Otto::ResponseHandlers::DefaultHandler).to have_received(:handle)
    end
  end
end
