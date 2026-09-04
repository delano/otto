# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::MCP do
  describe Otto::MCP::Validator do
    describe '#validate_request' do
      it 'rejects requests that do not match the MCP JSON-RPC schema' do
        validator = described_class.new

        expect { validator.validate_request('method' => 'initialize') }
          .to raise_error(Otto::MCP::ValidationError, /Invalid MCP request/)
      end

      it 'does not initialize when JSON Schema validation is unavailable' do
        error = Otto::OptionalDependencyError.new(
          "MCP JSON Schema validation requires optional dependency 'json_schemer' (~> 2.0)"
        )
        allow(Otto::OptionalDependency).to receive(:require!).and_raise(error)

        expect { described_class.new }
          .to raise_error(Otto::OptionalDependencyError, /json_schemer.*~> 2\.0/)
      end
    end
  end

  describe Otto::MCP::Server do
    subject(:server) { described_class.new(create_minimal_otto) }

    describe '#enable!' do
      it 'fails before enabling when schema validation is unavailable' do
        error = Otto::OptionalDependencyError.new('json_schemer is unavailable')
        allow(Otto::MCP::Validator).to receive(:ensure_available!).and_raise(error)

        expect { server.enable!(enable_rate_limiting: false) }
          .to raise_error(Otto::OptionalDependencyError, /json_schemer is unavailable/)
        expect(server).not_to be_enabled
      end

      it 'fails before enabling when rate limiting is unavailable' do
        error = Otto::OptionalDependencyError.new('rack-attack is unavailable')
        allow(Otto::MCP::Validator).to receive(:ensure_available!).and_return(true)
        allow(Otto::Security::RateLimiting).to receive(:ensure_available!).and_raise(error)

        expect { server.enable! }
          .to raise_error(Otto::OptionalDependencyError, /rack-attack is unavailable/)
        expect(server).not_to be_enabled
      end

      it 'does not require optional security gems when both features are disabled' do
        allow(Otto::MCP::Validator).to receive(:ensure_available!)
        allow(Otto::Security::RateLimiting).to receive(:ensure_available!)

        server.enable!(enable_validation: false, enable_rate_limiting: false)

        expect(server).to be_enabled
        expect(Otto::MCP::Validator).not_to have_received(:ensure_available!)
        expect(Otto::Security::RateLimiting).not_to have_received(:ensure_available!)
      end

      it 'requires optional security gems unless the features are explicitly false' do
        allow(Otto::MCP::Validator).to receive(:ensure_available!).and_call_original
        allow(Otto::Security::RateLimiting).to receive(:ensure_available!).and_call_original

        server.enable!(enable_validation: nil, enable_rate_limiting: nil)

        expect(Otto::MCP::Validator).to have_received(:ensure_available!).at_least(:once)
        expect(Otto::Security::RateLimiting).to have_received(:ensure_available!).at_least(:once)
      end
    end
  end
end
