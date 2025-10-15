# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto, 'configuration freezing' do
  let(:routes_file) { create_test_routes_file('freeze_test_routes.txt', ['GET / TestApp.index']) }

  describe 'automatic freezing on initialization' do
    it 'automatically freezes configuration after initialization in non-test environment' do
      # Temporarily hide RSpec to test production behavior
      rspec_constant = Object.send(:remove_const, :RSpec)

      otto = Otto.new(routes_file)

      expect(otto.frozen_configuration?).to be true

      # Restore RSpec
      Object.const_set(:RSpec, rspec_constant)
    end

    it 'skips freezing when RSpec is defined (test environment)' do
      otto = Otto.new(routes_file)
      expect(otto.frozen_configuration?).to be false
    end
  end

  describe 'frozen configuration prevents mutations' do
    let(:otto) do
      # Create otto and manually freeze it for testing
      o = Otto.new(routes_file)
      o.freeze_configuration!
      o
    end

    describe 'security configuration mutations' do
      it 'prevents enable_csrf_protection!' do
        expect { otto.enable_csrf_protection! }
          .to raise_error(FrozenError, /Cannot modify frozen configuration/)
      end

      it 'prevents enable_request_validation!' do
        expect { otto.enable_request_validation! }
          .to raise_error(FrozenError, /Cannot modify frozen configuration/)
      end

      it 'prevents enable_rate_limiting!' do
        expect { otto.enable_rate_limiting! }
          .to raise_error(FrozenError, /Cannot modify frozen configuration/)
      end

      it 'prevents add_rate_limit_rule' do
        expect { otto.add_rate_limit_rule('test', limit: 10) }
          .to raise_error(FrozenError, /Cannot modify frozen configuration/)
      end

      it 'prevents add_trusted_proxy' do
        expect { otto.add_trusted_proxy('10.0.0.1') }
          .to raise_error(FrozenError, /Cannot modify frozen configuration/)
      end

      it 'prevents set_security_headers' do
        expect { otto.set_security_headers({'x-custom' => 'value'}) }
          .to raise_error(FrozenError, /Cannot modify frozen configuration/)
      end

      it 'prevents enable_hsts!' do
        expect { otto.enable_hsts! }
          .to raise_error(FrozenError, /Cannot modify frozen configuration/)
      end

      it 'prevents enable_csp!' do
        expect { otto.enable_csp! }
          .to raise_error(FrozenError, /Cannot modify frozen configuration/)
      end

      it 'prevents enable_frame_protection!' do
        expect { otto.enable_frame_protection! }
          .to raise_error(FrozenError, /Cannot modify frozen configuration/)
      end

      it 'prevents enable_csp_with_nonce!' do
        expect { otto.enable_csp_with_nonce! }
          .to raise_error(FrozenError, /Cannot modify frozen configuration/)
      end
    end

    describe 'middleware stack mutations' do
      it 'prevents use/add middleware' do
        test_middleware = Class.new
        expect { otto.use(test_middleware) }
          .to raise_error(FrozenError, /Cannot modify frozen middleware stack/)
      end

      it 'prevents middleware removal' do
        expect { otto.middleware.remove(Otto::Security::Middleware::CSRFMiddleware) }
          .to raise_error(FrozenError, /Cannot modify frozen middleware stack/)
      end

      it 'prevents middleware clear' do
        expect { otto.middleware.clear! }
          .to raise_error(FrozenError, /Cannot modify frozen middleware stack/)
      end

      it 'prevents middleware_stack= assignment' do
        expect { otto.middleware_stack = [Class.new] }
          .to raise_error(FrozenError, /Cannot modify frozen middleware stack/)
      end
    end

    describe 'authentication configuration mutations' do
      it 'prevents add_auth_strategy' do
        strategy = double('strategy')
        expect { otto.add_auth_strategy('test', strategy) }
          .to raise_error(FrozenError, /Cannot modify frozen configuration/)
      end

      it 'prevents configure_auth_strategies' do
        expect { otto.configure_auth_strategies({}) }
          .to raise_error(FrozenError, /Cannot modify frozen configuration/)
      end
    end

    describe 'locale configuration mutations' do
      it 'prevents configure' do
        expect { otto.configure(available_locales: {'en' => 'English'}) }
          .to raise_error(FrozenError, /Cannot modify frozen configuration/)
      end
    end

    describe 'MCP configuration mutations' do
      it 'prevents enable_mcp!' do
        expect { otto.enable_mcp! }
          .to raise_error(FrozenError, /Cannot modify frozen configuration/)
      end
    end

    describe 'nested structure mutations' do
      it 'prevents modifying rate_limiting_config hash' do
        expect { otto.security_config.rate_limiting_config[:custom_rules] = {} }
          .to raise_error(FrozenError, /can't modify frozen/)
      end

      it 'prevents modifying auth_strategies hash' do
        expect { otto.auth_config[:auth_strategies] = {} }
          .to raise_error(FrozenError, /can't modify frozen/)
      end

      it 'prevents modifying security_headers hash' do
        expect { otto.security_config.security_headers['new-header'] = 'value' }
          .to raise_error(FrozenError, /can't modify frozen/)
      end

      it 'prevents modifying routes hash' do
        expect { otto.routes[:GET] = [] }
          .to raise_error(FrozenError, /can't modify frozen/)
      end

      it 'prevents modifying routes_literal hash' do
        expect { otto.routes_literal[:GET] = {} }
          .to raise_error(FrozenError, /can't modify frozen/)
      end

      it 'prevents modifying route_definitions hash' do
        expect { otto.route_definitions['test'] = {} }
          .to raise_error(FrozenError, /can't modify frozen/)
      end
    end
  end

  describe 'reading frozen configuration' do
    let(:otto) do
      o = Otto.new(routes_file)
      o.freeze_configuration!
      o
    end

    it 'allows reading security_config attributes' do
      expect { otto.security_config.csrf_enabled? }.not_to raise_error
      expect { otto.security_config.input_validation }.not_to raise_error
      expect { otto.security_config.max_request_size }.not_to raise_error
    end

    it 'allows reading middleware_list' do
      expect { otto.middleware.middleware_list }.not_to raise_error
      expect { otto.middleware_stack }.not_to raise_error
    end

    it 'allows checking middleware presence' do
      expect { otto.middleware.includes?(Otto::Security::Middleware::CSRFMiddleware) }.not_to raise_error
      expect { otto.middleware_enabled?(Otto::Security::Middleware::CSRFMiddleware) }.not_to raise_error
    end

    it 'allows reading routes' do
      expect { otto.routes }.not_to raise_error
      expect { otto.routes_literal }.not_to raise_error
      expect { otto.route_definitions }.not_to raise_error
    end

    it 'allows reading auth_config' do
      expect { otto.auth_config[:auth_strategies] }.not_to raise_error
      expect { otto.auth_config[:default_auth_strategy] }.not_to raise_error
    end
  end

  describe 'unfreeze_configuration! (test-only method)' do
    let(:otto) do
      o = Otto.new(routes_file)
      o.freeze_configuration!
      o
    end

    it 'allows unfreezing for tests' do
      expect(otto.frozen_configuration?).to be true
      otto.unfreeze_configuration!
      expect(otto.frozen_configuration?).to be false
    end

    it 'allows mutations after unfreezing' do
      otto.unfreeze_configuration!

      expect { otto.enable_csrf_protection! }.not_to raise_error
      expect { otto.add_trusted_proxy('10.0.0.1') }.not_to raise_error
      expect { otto.use(Class.new) }.not_to raise_error
    end
  end

  describe 'freeze_configuration! behavior' do
    let(:otto) { Otto.new(routes_file) }

    it 'can be called multiple times idempotently' do
      otto.freeze_configuration!
      expect { otto.freeze_configuration! }.not_to raise_error
      expect(otto.frozen_configuration?).to be true
    end

    it 'returns self for method chaining' do
      result = otto.freeze_configuration!
      expect(result).to eq(otto)
    end
  end

  describe 'security guarantees' do
    it 'prevents runtime security bypass via CSRF toggle' do
      # Hide RSpec to test production behavior
      rspec_constant = Object.send(:remove_const, :RSpec)

      otto = Otto.new(routes_file, csrf_protection: true)

      # Attempt to disable CSRF protection after initialization
      expect { otto.security_config.csrf_protection = false }
        .to raise_error(FrozenError)

      # Restore RSpec
      Object.const_set(:RSpec, rspec_constant)
    end

    it 'prevents adding malicious middleware after initialization' do
      # Hide RSpec to test production behavior
      rspec_constant = Object.send(:remove_const, :RSpec)

      otto = Otto.new(routes_file)

      malicious_middleware = Class.new do
        def initialize(app)
          @app = app
        end

        def call(env)
          # Malicious code would go here
          @app.call(env)
        end
      end

      expect { otto.use(malicious_middleware) }
        .to raise_error(FrozenError, /Cannot modify frozen middleware stack/)

      # Restore RSpec
      Object.const_set(:RSpec, rspec_constant)
    end

    it 'prevents modifying trusted proxies to bypass IP restrictions' do
      # Hide RSpec to test production behavior
      rspec_constant = Object.send(:remove_const, :RSpec)

      otto = Otto.new(routes_file, trusted_proxies: ['10.0.0.0/8'])

      expect { otto.add_trusted_proxy('0.0.0.0/0') }
        .to raise_error(FrozenError, /Cannot modify frozen configuration/)

      # Restore RSpec
      Object.const_set(:RSpec, rspec_constant)
    end
  end
end
