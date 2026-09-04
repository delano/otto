# spec/otto/security/authentication/route_auth_wrapper/role_authorization_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Path mirrors lib/otto/security/authentication/route_auth_wrapper/, not the
# RouteAuthWrapperComponents module name.
RSpec.describe Otto::Security::Authentication::RouteAuthWrapperComponents::RoleAuthorization do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:authorizer) { described_class.new(route_definition) }

  let(:route_definition) do
    Otto::RouteDefinition.new('GET', '/admin', 'TestApp.admin auth=apikey role=admin')
  end

  let(:env) { { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/admin' } }

  def result_for(user, metadata: {})
    Otto::Security::Authentication::StrategyResult.new(
      session: {},
      user: user,
      auth_method: 'apikey',
      metadata: metadata,
      strategy_name: 'apikey'
    )
  end

  describe '#check' do
    context 'with an object-backed user exposing #roles' do
      let(:user_class) do
        Class.new do
          def id = 7
          def roles = %w[admin]
        end
      end

      it 'authorizes when a role matches' do
        expect(authorizer.check(result_for(user_class.new), env)).to be(true)
      end

      it 'reports authorized? true' do
        expect(authorizer.authorized?(result_for(user_class.new))).to be(true)
      end
    end

    context 'with an object-backed user whose #roles do not match' do
      let(:user_class) do
        Class.new do
          def id = 7
          def roles = %w[viewer]
        end
      end

      it 'returns the failure hash' do
        expect(authorizer.check(result_for(user_class.new), env)).to eq(
          authorized: false,
          required: ['admin'],
          actual: ['viewer']
        )
      end
    end

    context 'with an object-backed user exposing no #roles at all' do
      let(:user_class) do
        Class.new do
          def id = 7
        end
      end

      it 'denies without raising' do
        outcome = nil
        expect { outcome = authorizer.check(result_for(user_class.new), env) }.not_to raise_error
        expect(outcome).to eq(authorized: false, required: ['admin'], actual: [])
      end

      it 'reports authorized? false' do
        expect(authorizer.authorized?(result_for(user_class.new))).to be(false)
      end

      it 'still honours metadata[:user_roles]' do
        result = result_for(user_class.new, metadata: { user_roles: ['admin'] })
        expect(authorizer.check(result, env)).to be(true)
      end
    end

    context 'with a Data instance user' do
      let(:user_data) { Data.define(:id, :roles) }

      it 'authorizes on matching #roles' do
        expect(authorizer.check(result_for(user_data.new(id: 1, roles: ['admin'])), env)).to be(true)
      end

      it 'denies when #roles is nil' do
        expect(authorizer.check(result_for(user_data.new(id: 1, roles: nil)), env))
          .to eq(authorized: false, required: ['admin'], actual: [])
      end
    end

    context 'with an ORM-like user responding to #[], #roles and #role' do
      let(:user_class) do
        Class.new do
          def initialize(roles:, role: nil)
            @roles = roles
            @role = role
          end

          attr_reader :roles, :role

          def id = 7
          def [](_key) = nil
        end
      end

      it 'authorizes on #roles, not #[]' do
        expect(authorizer.check(result_for(user_class.new(roles: [:admin])), env)).to be(true)
      end

      it 'authorizes on a Set of roles' do
        expect(authorizer.check(result_for(user_class.new(roles: Set['admin'])), env)).to be(true)
      end

      it 'denies on non-matching #roles even when #role would match' do
        expect(authorizer.check(result_for(user_class.new(roles: ['viewer'], role: 'admin')), env))
          .to eq(authorized: false, required: ['admin'], actual: ['viewer'])
      end
    end

    context 'with an object-backed user exposing only a singular #role' do
      let(:user_class) do
        Class.new do
          def id = 7
          def role = 'admin'
        end
      end

      it 'authorizes on #role' do
        expect(authorizer.check(result_for(user_class.new), env)).to be(true)
      end
    end

    context 'with a Hash user' do
      it 'authorizes via :roles' do
        expect(authorizer.check(result_for({ id: 1, roles: ['admin'] }), env)).to be(true)
      end

      it "authorizes via 'roles'" do
        expect(authorizer.check(result_for({ id: 1, 'roles' => ['admin'] }), env)).to be(true)
      end

      it 'denies when roles absent' do
        expect(authorizer.check(result_for({ id: 1 }), env))
          .to eq(authorized: false, required: ['admin'], actual: [])
      end
    end

    context 'without role requirements' do
      let(:route_definition) do
        Otto::RouteDefinition.new('GET', '/open', 'TestApp.open auth=apikey')
      end

      it 'authorizes any user, including one without #roles' do
        expect(authorizer.check(result_for(Object.new), env)).to be(true)
      end
    end
  end
end
