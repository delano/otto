# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Otto Error Classes' do
  describe 'base error class hierarchy' do
    describe 'Otto::HTTPError' do
      it 'inherits from StandardError' do
        expect(Otto::HTTPError.ancestors).to include(StandardError)
      end

      it 'defines default_status as 500' do
        expect(Otto::HTTPError.default_status).to eq(500)
      end

      it 'defines default_log_level as :error' do
        expect(Otto::HTTPError.default_log_level).to eq(:error)
      end
    end

    describe 'Otto::NotFoundError' do
      it 'inherits from HTTPError' do
        expect(Otto::NotFoundError.ancestors).to include(Otto::HTTPError)
      end

      it 'defines default_status as 404' do
        expect(Otto::NotFoundError.default_status).to eq(404)
      end

      it 'defines default_log_level as :info' do
        expect(Otto::NotFoundError.default_log_level).to eq(:info)
      end
    end

    describe 'Otto::BadRequestError' do
      it 'inherits from HTTPError' do
        expect(Otto::BadRequestError.ancestors).to include(Otto::HTTPError)
      end

      it 'defines default_status as 400' do
        expect(Otto::BadRequestError.default_status).to eq(400)
      end

      it 'defines default_log_level as :info' do
        expect(Otto::BadRequestError.default_log_level).to eq(:info)
      end
    end

    describe 'Otto::UnauthorizedError' do
      it 'inherits from HTTPError' do
        expect(Otto::UnauthorizedError.ancestors).to include(Otto::HTTPError)
      end

      it 'defines default_status as 401' do
        expect(Otto::UnauthorizedError.default_status).to eq(401)
      end

      it 'defines default_log_level as :info' do
        expect(Otto::UnauthorizedError.default_log_level).to eq(:info)
      end
    end

    describe 'Otto::ForbiddenError' do
      it 'inherits from HTTPError' do
        expect(Otto::ForbiddenError.ancestors).to include(Otto::HTTPError)
      end

      it 'defines default_status as 403' do
        expect(Otto::ForbiddenError.default_status).to eq(403)
      end

      it 'defines default_log_level as :warn' do
        expect(Otto::ForbiddenError.default_log_level).to eq(:warn)
      end
    end

    describe 'Otto::PayloadTooLargeError' do
      it 'inherits from HTTPError' do
        expect(Otto::PayloadTooLargeError.ancestors).to include(Otto::HTTPError)
      end

      it 'defines default_status as 413' do
        expect(Otto::PayloadTooLargeError.default_status).to eq(413)
      end

      it 'defines default_log_level as :warn' do
        expect(Otto::PayloadTooLargeError.default_log_level).to eq(:warn)
      end
    end
  end

  describe 'security error inheritance' do
    describe 'Otto::Security::AuthorizationError' do
      it 'inherits from Otto::ForbiddenError' do
        expect(Otto::Security::AuthorizationError.ancestors).to include(Otto::ForbiddenError)
      end

      it 'inherits from Otto::HTTPError' do
        expect(Otto::Security::AuthorizationError.ancestors).to include(Otto::HTTPError)
      end

      it 'preserves rich attributes (resource, action, user_id)' do
        error = Otto::Security::AuthorizationError.new(
          'Access denied',
          resource: 'Post',
          action: 'delete',
          user_id: 123
        )

        expect(error.resource).to eq('Post')
        expect(error.action).to eq('delete')
        expect(error.user_id).to eq(123)
      end

      it 'preserves to_log_data method' do
        error = Otto::Security::AuthorizationError.new(
          'Access denied',
          resource: 'Post',
          action: 'delete',
          user_id: 123
        )

        log_data = error.to_log_data
        expect(log_data).to include(
          error: 'Access denied',
          resource: 'Post',
          action: 'delete',
          user_id: 123
        )
      end
    end

    describe 'Otto::Security::CSRFError' do
      it 'inherits from Otto::ForbiddenError' do
        expect(Otto::Security::CSRFError.ancestors).to include(Otto::ForbiddenError)
      end

      it 'inherits from Otto::HTTPError' do
        expect(Otto::Security::CSRFError.ancestors).to include(Otto::HTTPError)
      end
    end

    describe 'Otto::Security::RequestTooLargeError' do
      it 'inherits from Otto::PayloadTooLargeError' do
        expect(Otto::Security::RequestTooLargeError.ancestors).to include(Otto::PayloadTooLargeError)
      end

      it 'inherits from Otto::HTTPError' do
        expect(Otto::Security::RequestTooLargeError.ancestors).to include(Otto::HTTPError)
      end
    end

    describe 'Otto::Security::ValidationError' do
      it 'inherits from Otto::BadRequestError' do
        expect(Otto::Security::ValidationError.ancestors).to include(Otto::BadRequestError)
      end

      it 'inherits from Otto::HTTPError' do
        expect(Otto::Security::ValidationError.ancestors).to include(Otto::HTTPError)
      end
    end
  end

  describe 'MCP error inheritance' do
    describe 'Otto::MCP::ValidationError' do
      it 'inherits from Otto::BadRequestError' do
        expect(Otto::MCP::ValidationError.ancestors).to include(Otto::BadRequestError)
      end

      it 'inherits from Otto::HTTPError' do
        expect(Otto::MCP::ValidationError.ancestors).to include(Otto::HTTPError)
      end

      it 'is distinct from Otto::Security::ValidationError' do
        expect(Otto::MCP::ValidationError).not_to eq(Otto::Security::ValidationError)
      end
    end
  end
end
