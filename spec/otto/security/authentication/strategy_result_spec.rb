# spec/otto/security/authentication/strategy_result_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Security::Authentication::StrategyResult do
  def build(user)
    described_class.new(
      session: {},
      user: user,
      auth_method: 'apikey',
      metadata: {},
      strategy_name: 'apikey'
    )
  end

  describe '#roles' do
    context 'with a Hash user' do
      it 'reads :roles' do
        expect(build({ roles: [:admin, 'editor'] }).roles).to eq(%w[admin editor])
      end

      it "reads 'roles'" do
        expect(build({ 'roles' => ['admin'] }).roles).to eq(['admin'])
      end

      it 'falls back to :role' do
        expect(build({ role: :admin }).roles).to eq(['admin'])
      end

      it 'returns [] when neither key is present' do
        expect(build({ id: 1 }).roles).to eq([])
      end
    end

    context 'with a PORO user exposing #roles' do
      let(:user_class) do
        Class.new do
          def roles = [:admin, 'editor']
        end
      end

      it 'normalizes the array to strings' do
        expect(build(user_class.new).roles).to eq(%w[admin editor])
      end
    end

    context 'with a PORO user exposing a single #roles value' do
      let(:user_class) do
        Class.new do
          def roles = :admin
        end
      end

      it 'wraps the scalar' do
        expect(build(user_class.new).roles).to eq(['admin'])
      end
    end

    context 'with a PORO user exposing #role only' do
      let(:user_class) do
        Class.new do
          def role = :editor
        end
      end

      it 'uses the single role' do
        expect(build(user_class.new).roles).to eq(['editor'])
      end
    end

    context 'with a PORO user whose #roles is nil but #role is set' do
      let(:user_class) do
        Class.new do
          def roles = nil
          def role = 'viewer'
        end
      end

      it 'falls through to #role' do
        expect(build(user_class.new).roles).to eq(['viewer'])
      end
    end

    context 'with a PORO user exposing neither #roles nor #role' do
      let(:user_class) do
        Class.new do
          def id = 42
        end
      end

      it 'returns [] without raising' do
        expect(build(user_class.new).roles).to eq([])
      end

      it 'does not raise from #to_h' do
        expect { build(user_class.new).to_h }.not_to raise_error
      end

      it 'does not raise from #inspect' do
        expect(build(user_class.new).inspect).to include('roles=[]')
      end
    end

    context 'with a Data instance user' do
      let(:user_data) { Data.define(:id, :roles) }

      it 'reads #roles' do
        expect(build(user_data.new(id: 1, roles: ['admin'])).roles).to eq(['admin'])
      end
    end

    context 'with a Data instance user lacking a roles member' do
      let(:user_data) { Data.define(:id) }

      it 'returns [] without raising' do
        expect(build(user_data.new(id: 1)).roles).to eq([])
      end
    end

    context 'with a Struct instance user' do
      let(:user_struct) { Struct.new(:id, :roles) }

      it 'reads #roles' do
        expect(build(user_struct.new(1, [:admin])).roles).to eq(['admin'])
      end

      it 'returns [] when roles is nil' do
        expect(build(user_struct.new(1, nil)).roles).to eq([])
      end
    end

    context 'with a Struct instance user lacking a roles member' do
      let(:user_struct) { Struct.new(:id) }

      it 'returns [] without calling #[]' do
        expect(build(user_struct.new(1)).roles).to eq([])
      end
    end

    context 'with an ORM-like user responding to #[], #roles and #role' do
      let(:user_class) do
        Class.new do
          def initialize(roles:, role: nil)
            @attrs = { 'role' => role }
            @roles = roles
          end

          attr_reader :roles

          def id = 7
          def [](key) = @attrs[key.to_s]
          def role = @attrs['role']
        end
      end

      it 'prefers #roles over #[] and #role' do
        expect(build(user_class.new(roles: %w[admin editor], role: 'viewer')).roles).to eq(%w[admin editor])
      end

      it 'falls back to #role when #roles is empty' do
        expect(build(user_class.new(roles: [], role: 'viewer')).roles).to eq(['viewer'])
      end

      it 'expands a Set of roles' do
        expect(build(user_class.new(roles: Set['admin', :editor])).roles).to eq(%w[admin editor])
      end
    end

    it 'returns [] when anonymous' do
      expect(described_class.anonymous.roles).to eq([])
    end
  end

  describe '#permissions' do
    context 'with a Hash user' do
      it 'reads :permissions' do
        expect(build({ permissions: [:read, 'write'] }).permissions).to eq(%w[read write])
      end

      it "reads 'permissions'" do
        expect(build({ 'permissions' => 'read' }).permissions).to eq(['read'])
      end

      it 'returns [] when absent' do
        expect(build({ id: 1 }).permissions).to eq([])
      end
    end

    context 'with a PORO user exposing #permissions' do
      let(:user_class) do
        Class.new do
          def permissions = [:read, 'write']
        end
      end

      it 'normalizes to strings' do
        expect(build(user_class.new).permissions).to eq(%w[read write])
      end
    end

    context 'with a PORO user exposing a scalar #permissions' do
      let(:user_class) do
        Class.new do
          def permissions = :read
        end
      end

      it 'wraps the scalar' do
        expect(build(user_class.new).permissions).to eq(['read'])
      end
    end

    context 'with a PORO user without #permissions' do
      let(:user_class) do
        Class.new do
          def id = 42
        end
      end

      it 'returns [] without raising' do
        expect(build(user_class.new).permissions).to eq([])
      end

      it 'does not raise from #to_h' do
        expect(build(user_class.new).to_h).to include(roles: [], permissions: [])
      end
    end

    context 'with a Data instance user' do
      let(:user_data) { Data.define(:id, :permissions) }

      it 'reads #permissions' do
        expect(build(user_data.new(id: 1, permissions: ['read'])).permissions).to eq(['read'])
      end

      it 'returns [] when permissions is nil' do
        expect(build(user_data.new(id: 1, permissions: nil)).permissions).to eq([])
      end
    end

    context 'with a Struct instance user lacking a permissions member' do
      let(:user_struct) { Struct.new(:id) }

      it 'returns [] without calling #[]' do
        expect(build(user_struct.new(1)).permissions).to eq([])
      end
    end

    it 'returns [] when anonymous' do
      expect(described_class.anonymous.permissions).to eq([])
    end
  end
end
