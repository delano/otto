# spec/otto/auth_config_sharing_spec.rb

require 'spec_helper'

RSpec.describe 'Auth Config Sharing' do
  let(:otto) { Otto.new }
  let(:test_strategy) { double('TestStrategy') }
  let(:admin_strategy) { double('AdminStrategy') }

  describe 'auth config synchronization between Otto and Configurator' do
    it 'shares auth config between Otto instance and security configurator' do
      # Add strategy via Otto instance
      otto.add_auth_strategy('test', test_strategy)

      # Should be available in configurator's auth config
      expect(otto.security.auth_config[:auth_strategies]['test']).to eq(test_strategy)
    end

    it 'maintains default auth strategy consistency' do
      # Otto should have default auth strategy
      expect(otto.security.auth_config[:default_auth_strategy]).to eq('noauth')

      # Should match Otto's auth config
      expect(otto.auth_config[:default_auth_strategy]).to eq('noauth')
    end

    it 'updates both configs when adding strategy via Otto' do
      otto.add_auth_strategy('admin', admin_strategy)

      # Check Otto's auth config
      expect(otto.auth_config[:auth_strategies]['admin']).to eq(admin_strategy)

      # Check configurator's auth config
      expect(otto.security.auth_config[:auth_strategies]['admin']).to eq(admin_strategy)
    end

    it 'updates configurator when using configure_auth_strategies on Otto' do
      strategies = {
        'public' => test_strategy,
        'admin' => admin_strategy,
      }

      otto.configure_auth_strategies(strategies, default_strategy: 'admin')

      # Check configurator has the same config
      expect(otto.security.auth_config[:auth_strategies]).to eq(strategies)
      expect(otto.security.auth_config[:default_auth_strategy]).to eq('admin')
    end

    it 'configures authentication strategies when added' do
      otto.add_auth_strategy('test', test_strategy)

      # Should configure strategy in auth_config
      expect(otto.auth_config[:auth_strategies]['test']).to eq(test_strategy)

      # Should be available in configurator
      expect(otto.security.auth_config[:auth_strategies]['test']).to eq(test_strategy)
    end
  end

  describe 'configurator-initiated auth configuration' do
    it 'updates configurator auth config when adding strategies' do
      otto.security.add_auth_strategy('test', test_strategy)

      expect(otto.security.auth_config[:auth_strategies]['test']).to eq(test_strategy)
    end

    it 'configures strategy when adding via configurator' do
      otto.security.add_auth_strategy('test', test_strategy)

      expect(otto.security.auth_config[:auth_strategies]['test']).to eq(test_strategy)
    end

    it 'configures multiple strategies via configurator' do
      strategies = {
        'public' => test_strategy,
        'admin' => admin_strategy,
      }

      otto.security.configure_auth_strategies(strategies, default_strategy: 'admin')

      expect(otto.security.auth_config[:auth_strategies]).to eq(strategies)
      expect(otto.security.auth_config[:default_auth_strategy]).to eq('admin')
    end

    it 'handles empty strategies configuration' do
      otto.security.configure_auth_strategies({})

      expect(otto.security.auth_config[:auth_strategies]).to eq({})
    end
  end

  describe 'initialization with auth strategies' do
    it 'properly configures auth from initialization options' do
      strategies = {
        'public' => test_strategy,
        'admin' => admin_strategy,
      }

      otto_with_auth = Otto.new(nil, {
                                  auth_strategies: strategies,
        default_auth_strategy: 'admin',
                                })

      # Check Otto's auth config
      expect(otto_with_auth.auth_config[:auth_strategies]).to eq(strategies)
      expect(otto_with_auth.auth_config[:default_auth_strategy]).to eq('admin')

      # Check configurator's auth config shares the same config as Otto instance
      expect(otto_with_auth.security.auth_config[:auth_strategies]).to eq(strategies) # Configurator shares Otto's config
      expect(otto_with_auth.security.auth_config[:default_auth_strategy]).to eq('admin')
    end
  end

  describe 'auth config isolation between instances' do
    let(:otto1) { Otto.new }
    let(:otto2) { Otto.new }
    let(:strategy1) { double('Strategy1') }
    let(:strategy2) { double('Strategy2') }

    it 'maintains separate auth configs for different Otto instances' do
      otto1.add_auth_strategy('test1', strategy1)
      otto2.add_auth_strategy('test2', strategy2)

      # Otto1 should only have strategy1
      expect(otto1.auth_config[:auth_strategies]['test1']).to eq(strategy1)
      expect(otto1.auth_config[:auth_strategies]['test2']).to be_nil
      expect(otto1.security.auth_config[:auth_strategies]['test1']).to eq(strategy1)

      # Otto2 should only have strategy2
      expect(otto2.auth_config[:auth_strategies]['test2']).to eq(strategy2)
      expect(otto2.auth_config[:auth_strategies]['test1']).to be_nil
      expect(otto2.security.auth_config[:auth_strategies]['test2']).to eq(strategy2)
    end

    it 'maintains separate configurator auth configs' do
      otto1.security.add_auth_strategy('config1', strategy1)
      otto2.security.add_auth_strategy('config2', strategy2)

      # Configurators should have separate configs
      expect(otto1.security.auth_config[:auth_strategies]['config1']).to eq(strategy1)
      expect(otto1.security.auth_config[:auth_strategies]['config2']).to be_nil

      expect(otto2.security.auth_config[:auth_strategies]['config2']).to eq(strategy2)
      expect(otto2.security.auth_config[:auth_strategies]['config1']).to be_nil
    end
  end

  describe 'auth config availability' do
    it 'makes auth config available to route handlers' do
      otto.add_auth_strategy('test', test_strategy)

      # The auth config should be accessible for route handlers
      expect(otto.auth_config[:auth_strategies]['test']).to eq(test_strategy)
      expect(otto.security.auth_config).to eq(otto.auth_config)
    end
  end

  describe 'auth config edge cases' do
    it 'handles nil auth_config gracefully' do
      # Reset auth config to nil
      otto.instance_variable_set(:@auth_config, nil)

      # Adding strategy should initialize config
      otto.add_auth_strategy('test', test_strategy)

      expect(otto.auth_config).to be_a(Hash)
      expect(otto.auth_config[:auth_strategies]['test']).to eq(test_strategy)
      expect(otto.auth_config[:default_auth_strategy]).to eq('noauth')
    end

    it 'handles adding multiple strategies' do
      otto.add_auth_strategy('strategy1', test_strategy)
      otto.add_auth_strategy('strategy2', admin_strategy)

      expect(otto.auth_config[:auth_strategies]).to have_key('strategy1')
      expect(otto.auth_config[:auth_strategies]).to have_key('strategy2')
      expect(otto.auth_config[:auth_strategies]['strategy1']).to eq(test_strategy)
      expect(otto.auth_config[:auth_strategies]['strategy2']).to eq(admin_strategy)

      # Configurator should track its own additions
      expect(otto.security.auth_config[:auth_strategies]).to have_key('strategy1')
      expect(otto.security.auth_config[:auth_strategies]).to have_key('strategy2')
    end

    it 'overwrites existing strategies with same name' do
      new_strategy = double('NewStrategy')

      otto.add_auth_strategy('test', test_strategy)
      otto.add_auth_strategy('test', new_strategy)

      expect(otto.auth_config[:auth_strategies]['test']).to eq(new_strategy)
      expect(otto.security.auth_config[:auth_strategies]['test']).to eq(new_strategy)
    end
  end
end
