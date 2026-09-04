# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::OptionalDependency do
  describe '.require!' do
    it 'reports a missing optional dependency with the feature and install requirement' do
      allow(Gem::Specification).to receive(:find_all_by_name).with('example-gem').and_return([])

      expect do
        described_class.require!(
          'example-gem',
          '~> 2.0',
          require_path: 'example/gem',
          feature: 'Example validation'
        )
      end.to raise_error(Otto::OptionalDependencyError) { |error|
        expect(error.message).to include("Example validation requires optional dependency 'example-gem' (~> 2.0)")
        expect(error.message).to include('it is not installed')
        expect(error.message).to include("gem 'example-gem', '~> 2.0'")
      }
    end

    it 'reports installed versions outside the supported range' do
      old_spec = instance_double(Gem::Specification, version: Gem::Version.new('1.9.0'))
      allow(Gem::Specification).to receive(:find_all_by_name).with('example-gem').and_return([old_spec])

      expect do
        described_class.require!(
          'example-gem',
          '~> 2.0',
          require_path: 'example/gem',
          feature: 'Example validation'
        )
      end.to raise_error(Otto::OptionalDependencyError) { |error|
        expect(error.message).to include('installed version(s) 1.9.0 are incompatible')
      }
    end

    it 'uses an already-active compatible version instead of activating a newer installed version' do
      active_spec = instance_double(Gem::Specification, version: Gem::Version.new('2.0.0'))
      newer_spec = instance_double(Gem::Specification, version: Gem::Version.new('2.1.0'))
      allow(Gem::Specification).to receive(:find_all_by_name)
        .with('example-gem')
        .and_return([active_spec, newer_spec])
      allow(Gem).to receive(:loaded_specs).and_return('example-gem' => active_spec)
      allow(described_class).to receive(:require).with('example/gem').and_return(true)
      allow(active_spec).to receive(:activate)

      result = described_class.require!(
        'example-gem',
        '~> 2.0',
        require_path: 'example/gem',
        feature: 'Example validation'
      )

      expect(result).to eq(active_spec)
      expect(active_spec).to have_received(:activate)
    end

    it 'reports a require failure after a compatible version activates' do
      spec = instance_double(Gem::Specification, version: Gem::Version.new('2.0.0'))
      allow(Gem::Specification).to receive(:find_all_by_name).with('example-gem').and_return([spec])
      allow(Gem).to receive(:loaded_specs).and_return({})
      allow(spec).to receive(:activate)
      allow(described_class).to receive(:require)
        .with('example/gem')
        .and_raise(LoadError, 'cannot load such file -- example/gem')

      expect do
        described_class.require!(
          'example-gem',
          '~> 2.0',
          require_path: 'example/gem',
          feature: 'Example validation'
        )
      end.to raise_error(Otto::OptionalDependencyError) { |error|
        expect(error.message).to include("Example validation requires optional dependency 'example-gem' (~> 2.0)")
        expect(error.message).to include('could not be loaded: cannot load such file -- example/gem')
        expect(error.message).to include("gem 'example-gem', '~> 2.0'")
        expect(error.cause).to be_a(LoadError)
      }
    end

    it 'reports an activation conflict as a load failure' do
      spec = instance_double(Gem::Specification, version: Gem::Version.new('2.0.0'))
      allow(Gem::Specification).to receive(:find_all_by_name).with('example-gem').and_return([spec])
      allow(Gem).to receive(:loaded_specs).and_return({})
      allow(spec).to receive(:activate).and_raise(Gem::LoadError, 'conflicts with activated example-gem-1.0.0')
      allow(described_class).to receive(:require)

      expect do
        described_class.require!(
          'example-gem',
          '~> 2.0',
          require_path: 'example/gem',
          feature: 'Example validation'
        )
      end.to raise_error(Otto::OptionalDependencyError) { |error|
        expect(error.message).to include('could not be loaded: conflicts with activated example-gem-1.0.0')
        expect(error.cause).to be_a(Gem::LoadError)
      }
      expect(described_class).not_to have_received(:require)
    end
  end
end
