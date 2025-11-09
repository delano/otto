# spec/otto/route_definition_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::RouteDefinition do
  describe '#auth_requirements' do
    it 'returns empty array when auth option is not present' do
      route = described_class.new('GET', '/public', 'TestApp.public')

      expect(route.auth_requirements).to eq([])
    end

    it 'returns single-element array for single auth requirement' do
      route = described_class.new('GET', '/protected', 'TestApp.protected auth=session')

      expect(route.auth_requirements).to eq(['session'])
    end

    it 'returns multiple elements for comma-separated auth requirements' do
      route = described_class.new('GET', '/protected', 'TestApp.protected auth=session,apikey,oauth')

      expect(route.auth_requirements).to eq(['session', 'apikey', 'oauth'])
    end

    it 'strips whitespace from auth requirements' do
      route = described_class.new('GET', '/protected', 'TestApp.protected auth=session, apikey , oauth')

      expect(route.auth_requirements).to eq(['session', 'apikey', 'oauth'])
    end

    it 'removes empty elements from auth requirements' do
      route = described_class.new('GET', '/protected', 'TestApp.protected auth=session,,apikey')

      expect(route.auth_requirements).to eq(['session', 'apikey'])
    end

    it 'handles auth with colon-separated values' do
      route = described_class.new('GET', '/protected', 'TestApp.protected auth=custom:value,session')

      expect(route.auth_requirements).to eq(['custom:value', 'session'])
    end
  end

  describe '#auth_requirement (backward compatibility)' do
    it 'returns nil when auth option is not present' do
      route = described_class.new('GET', '/public', 'TestApp.public')

      expect(route.auth_requirement).to be_nil
    end

    it 'returns single auth requirement' do
      route = described_class.new('GET', '/protected', 'TestApp.protected auth=session')

      expect(route.auth_requirement).to eq('session')
    end

    it 'returns first auth requirement for multi-strategy routes' do
      route = described_class.new('GET', '/protected', 'TestApp.protected auth=session,apikey,oauth')

      expect(route.auth_requirement).to eq('session')
    end
  end

  describe '#has_option?' do
    it 'returns true for present options' do
      route = described_class.new('GET', '/test', 'TestApp.test auth=session csrf=exempt')

      expect(route.has_option?(:auth)).to be true
      expect(route.has_option?(:csrf)).to be true
      expect(route.has_option?('auth')).to be true
    end

    it 'returns false for absent options' do
      route = described_class.new('GET', '/test', 'TestApp.test auth=session')

      expect(route.has_option?(:csrf)).to be false
      expect(route.has_option?(:nonexistent)).to be false
    end
  end

  describe '#option' do
    it 'returns option value when present' do
      route = described_class.new('GET', '/test', 'TestApp.test auth=session response=json')

      expect(route.option(:auth)).to eq('session')
      expect(route.option(:response)).to eq('json')
    end

    it 'returns nil for absent options' do
      route = described_class.new('GET', '/test', 'TestApp.test auth=session')

      expect(route.option(:nonexistent)).to be_nil
    end

    it 'returns default value for absent options' do
      route = described_class.new('GET', '/test', 'TestApp.test auth=session')

      expect(route.option(:nonexistent, 'default')).to eq('default')
    end
  end

  describe '#csrf_exempt?' do
    it 'returns true when csrf=exempt' do
      route = described_class.new('GET', '/test', 'TestApp.test csrf=exempt')

      expect(route.csrf_exempt?).to be true
    end

    it 'returns false when csrf option is absent' do
      route = described_class.new('GET', '/test', 'TestApp.test')

      expect(route.csrf_exempt?).to be false
    end

    it 'returns false when csrf has other value' do
      route = described_class.new('GET', '/test', 'TestApp.test csrf=enabled')

      expect(route.csrf_exempt?).to be false
    end
  end

  describe '#logic_route?' do
    it 'returns true for Logic class routes (bare class name)' do
      route = described_class.new('GET', '/test', 'TestLogic')

      expect(route.logic_route?).to be true
    end

    it 'returns false for instance method routes' do
      route = described_class.new('GET', '/test', 'TestApp#index')

      expect(route.logic_route?).to be false
    end

    it 'returns false for class method routes' do
      route = described_class.new('GET', '/test', 'TestApp.index')

      expect(route.logic_route?).to be false
    end
  end

  describe '#to_h' do
    it 'returns hash representation of route definition' do
      route = described_class.new('GET', '/test', 'TestApp.index auth=session')

      hash = route.to_h

      expect(hash[:verb]).to eq(:GET)
      expect(hash[:path]).to eq('/test')
      expect(hash[:target]).to eq('TestApp.index')
      expect(hash[:options]).to eq({ auth: 'session' })
      expect(hash[:kind]).to eq(:class)
    end
  end

  describe '#role_requirement' do
    it 'returns nil when role option is not present' do
      route = described_class.new('GET', '/public', 'TestApp.public')

      expect(route.role_requirement).to be_nil
    end

    it 'returns single role requirement' do
      route = described_class.new('GET', '/admin', 'AdminLogic auth=session role=admin')

      expect(route.role_requirement).to eq('admin')
    end

    it 'returns comma-separated role requirements as string' do
      route = described_class.new('GET', '/content', 'ContentLogic auth=session role=admin,editor')

      expect(route.role_requirement).to eq('admin,editor')
    end
  end

  describe '#role_requirements' do
    it 'returns empty array when role option is not present' do
      route = described_class.new('GET', '/public', 'TestApp.public')

      expect(route.role_requirements).to eq([])
    end

    it 'returns single-element array for single role requirement' do
      route = described_class.new('GET', '/admin', 'AdminLogic auth=session role=admin')

      expect(route.role_requirements).to eq(['admin'])
    end

    it 'returns multiple elements for comma-separated role requirements' do
      route = described_class.new('GET', '/content', 'ContentLogic auth=session role=admin,editor,moderator')

      expect(route.role_requirements).to eq(['admin', 'editor', 'moderator'])
    end

    it 'strips whitespace from role requirements' do
      route = described_class.new('GET', '/content', 'ContentLogic auth=session role=admin, editor , moderator')

      expect(route.role_requirements).to eq(['admin', 'editor', 'moderator'])
    end

    it 'removes empty elements from role requirements' do
      route = described_class.new('GET', '/content', 'ContentLogic auth=session role=admin,,editor')

      expect(route.role_requirements).to eq(['admin', 'editor'])
    end
  end

  describe 'immutability' do
    it 'freezes the route definition instance' do
      route = described_class.new('GET', '/test', 'TestApp.test')

      expect(route).to be_frozen
    end

    it 'freezes the options hash' do
      route = described_class.new('GET', '/test', 'TestApp.test auth=session')

      expect(route.options).to be_frozen
    end
  end
end
