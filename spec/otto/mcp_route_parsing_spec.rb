# frozen_string_literal: true
# spec/otto/mcp_route_parsing_spec.rb

require 'spec_helper'

RSpec.describe Otto, 'MCP Route Parsing' do
  let(:app) { Otto.new }

  before do
    # Mock the required MCP classes
    stub_const('Otto::MCP::RouteParser', Class.new do
      def self.parse_mcp_route(_verb, _path, definition)
        parts = definition.split(/\s+/, 3)

        raise ArgumentError, "Expected MCP keyword, got: #{parts[0]}" if parts[0] != 'MCP'

        resource_uri = parts[1]
        handler_definition = parts[2]

        raise ArgumentError, "Invalid MCP route format: #{definition}" unless resource_uri && handler_definition

        # Clean up URI - remove leading slash if present
        resource_uri = resource_uri.sub(%r{^/}, '')

        {
          type: :mcp_resource,
          resource_uri: resource_uri,
          handler: handler_definition,
          options: {},
        }
      end

      def self.parse_tool_route(_verb, _path, definition)
        parts = definition.split(/\s+/, 3)

        raise ArgumentError, "Expected TOOL keyword, got: #{parts[0]}" if parts[0] != 'TOOL'

        tool_name = parts[1]
        handler_definition = parts[2]

        raise ArgumentError, "Invalid TOOL route format: #{definition}" unless tool_name && handler_definition

        {
          type: :mcp_tool,
          tool_name: tool_name,
          handler: handler_definition,
          options: {},
        }
      end
    end)

    stub_const('Otto::MCP::Server', Class.new do
      def initialize(otto_instance); end
      def register_mcp_route(route_info); end
    end)
  end

  describe '#handle_mcp_route' do
    context 'when MCP server is not initialized' do
      it 'logs error when MCP server is missing' do
        definition = 'MCP files/test TestHandler.handle'

        expect(Otto.logger).to receive(:error)
          .with(/\[MCP\] Failed to parse MCP route: #{Regexp.escape(definition)} - undefined method [`']register_mcp_route[`'] for nil/)

        app.send(:handle_mcp_route, 'GET', '/resource', definition)
      end
    end

    context 'when MCP server is initialized' do
      before do
        # Initialize MCP server
        app.instance_variable_set(:@mcp_server, Otto::MCP::Server.new(app))
      end

      it 'parses and registers valid MCP route' do
        definition = 'MCP files/test TestHandler.handle'
        expect(Otto::MCP::RouteParser).to receive(:parse_mcp_route)
          .with('GET', '/resource', definition)
          .and_return({
                        type: :mcp_resource,
            resource_uri: 'files/test',
            handler: 'TestHandler.handle',
            options: {},
                      })

        expect(app.instance_variable_get(:@mcp_server)).to receive(:register_mcp_route)
          .with({
                  type: :mcp_resource,
            resource_uri: 'files/test',
            handler: 'TestHandler.handle',
            options: {},
                })

        allow(Otto.logger).to receive(:debug)

        app.send(:handle_mcp_route, 'GET', '/resource', definition)
      end

      it 'logs debug message when debug is enabled and route is registered' do
        original_debug = Otto.debug
        Otto.debug = true

        definition = 'MCP files/test TestHandler.handle'
        allow(Otto::MCP::RouteParser).to receive(:parse_mcp_route).and_return({
                                                                                type: :mcp_resource,
          resource_uri: 'files/test',
          handler: 'TestHandler.handle',
          options: {},
                                                                              })
        allow(app.instance_variable_get(:@mcp_server)).to receive(:register_mcp_route)

        expect(Otto.logger).to receive(:debug).with("[MCP] Registered resource route: #{definition}")

        app.send(:handle_mcp_route, 'GET', '/resource', definition)

        Otto.debug = original_debug
      end

      it 'handles parsing errors gracefully and logs them' do
        definition = 'INVALID format'
        allow(Otto::MCP::RouteParser).to receive(:parse_mcp_route)
          .with('GET', '/resource', definition)
          .and_raise(ArgumentError, 'Expected MCP keyword')

        expect(Otto.logger).to receive(:error)
          .with('[MCP] Failed to parse MCP route: INVALID format - Expected MCP keyword')

        app.send(:handle_mcp_route, 'GET', '/resource', definition)
      end

      it 'handles registration errors gracefully and logs them' do
        definition = 'MCP files/test TestHandler.handle'
        allow(Otto::MCP::RouteParser).to receive(:parse_mcp_route).and_return({
                                                                                type: :mcp_resource,
          resource_uri: 'files/test',
          handler: 'TestHandler.handle',
          options: {},
                                                                              })
        allow(app.instance_variable_get(:@mcp_server)).to receive(:register_mcp_route)
          .and_raise(RuntimeError, 'Registration failed')

        expect(Otto.logger).to receive(:error)
          .with('[MCP] Failed to parse MCP route: MCP files/test TestHandler.handle - Registration failed')

        app.send(:handle_mcp_route, 'GET', '/resource', definition)
      end

      it 'passes correct parameters to RouteParser' do
        definition = 'MCP config/settings ConfigHandler.get_settings'

        expect(Otto::MCP::RouteParser).to receive(:parse_mcp_route)
          .with('POST', '/api/config', definition)
          .and_return({
                        type: :mcp_resource,
            resource_uri: 'config/settings',
            handler: 'ConfigHandler.get_settings',
            options: {},
                      })

        allow(app.instance_variable_get(:@mcp_server)).to receive(:register_mcp_route)
        allow(Otto.logger).to receive(:debug)

        app.send(:handle_mcp_route, 'POST', '/api/config', definition)
      end
    end
  end

  describe '#handle_tool_route' do
    context 'when MCP server is not initialized' do
      it 'logs error when MCP server is missing' do
        definition = 'TOOL search_files SearchTool.execute'

        expect(Otto.logger).to receive(:error)
          .with(/\[MCP\] Failed to parse TOOL route: #{Regexp.escape(definition)} - undefined method [`']register_mcp_route[`'] for nil/)

        app.send(:handle_tool_route, 'POST', '/tool', definition)
      end
    end

    context 'when MCP server is initialized' do
      before do
        # Initialize MCP server
        app.instance_variable_set(:@mcp_server, Otto::MCP::Server.new(app))
      end

      it 'parses and registers valid TOOL route' do
        definition = 'TOOL search_files SearchTool.execute'
        expect(Otto::MCP::RouteParser).to receive(:parse_tool_route)
          .with('POST', '/tool', definition)
          .and_return({
                        type: :mcp_tool,
            tool_name: 'search_files',
            handler: 'SearchTool.execute',
            options: {},
                      })

        expect(app.instance_variable_get(:@mcp_server)).to receive(:register_mcp_route)
          .with({
                  type: :mcp_tool,
            tool_name: 'search_files',
            handler: 'SearchTool.execute',
            options: {},
                })

        allow(Otto.logger).to receive(:debug)

        app.send(:handle_tool_route, 'POST', '/tool', definition)
      end

      it 'logs debug message when debug is enabled and tool route is registered' do
        original_debug = Otto.debug
        Otto.debug = true

        definition = 'TOOL calculate MathTool.calculate'
        allow(Otto::MCP::RouteParser).to receive(:parse_tool_route).and_return({
                                                                                 type: :mcp_tool,
          tool_name: 'calculate',
          handler: 'MathTool.calculate',
          options: {},
                                                                               })
        allow(app.instance_variable_get(:@mcp_server)).to receive(:register_mcp_route)

        expect(Otto.logger).to receive(:debug).with("[MCP] Registered tool route: #{definition}")

        app.send(:handle_tool_route, 'POST', '/tool', definition)

        Otto.debug = original_debug
      end

      it 'handles parsing errors gracefully and logs them' do
        definition = 'INVALID tool format'
        allow(Otto::MCP::RouteParser).to receive(:parse_tool_route)
          .with('POST', '/tool', definition)
          .and_raise(ArgumentError, 'Expected TOOL keyword')

        expect(Otto.logger).to receive(:error)
          .with('[MCP] Failed to parse TOOL route: INVALID tool format - Expected TOOL keyword')

        app.send(:handle_tool_route, 'POST', '/tool', definition)
      end

      it 'handles registration errors gracefully and logs them' do
        definition = 'TOOL file_operations FileOps.process'
        allow(Otto::MCP::RouteParser).to receive(:parse_tool_route).and_return({
                                                                                 type: :mcp_tool,
          tool_name: 'file_operations',
          handler: 'FileOps.process',
          options: {},
                                                                               })
        allow(app.instance_variable_get(:@mcp_server)).to receive(:register_mcp_route)
          .and_raise(RuntimeError, 'Tool registration failed')

        expect(Otto.logger).to receive(:error)
          .with('[MCP] Failed to parse TOOL route: TOOL file_operations FileOps.process - Tool registration failed')

        app.send(:handle_tool_route, 'POST', '/tool', definition)
      end

      it 'passes correct parameters to RouteParser' do
        definition = 'TOOL database_query DbTool.query'

        expect(Otto::MCP::RouteParser).to receive(:parse_tool_route)
          .with('GET', '/api/tools', definition)
          .and_return({
                        type: :mcp_tool,
            tool_name: 'database_query',
            handler: 'DbTool.query',
            options: {},
                      })

        allow(app.instance_variable_get(:@mcp_server)).to receive(:register_mcp_route)
        allow(Otto.logger).to receive(:debug)

        app.send(:handle_tool_route, 'GET', '/api/tools', definition)
      end
    end
  end

  describe 'MCP route parsing behavior' do
    before do
      app.instance_variable_set(:@mcp_server, Otto::MCP::Server.new(app))
    end

    context 'error handling consistency' do
      it 'logs errors with consistent format for MCP routes' do
        allow(Otto::MCP::RouteParser).to receive(:parse_mcp_route)
          .and_raise(StandardError, 'Generic error')

        expect(Otto.logger).to receive(:error)
          .with(/\[MCP\] Failed to parse MCP route: .* - Generic error/)

        app.send(:handle_mcp_route, 'GET', '/test', 'MCP test TestHandler.test')
      end

      it 'logs errors with consistent format for TOOL routes' do
        allow(Otto::MCP::RouteParser).to receive(:parse_tool_route)
          .and_raise(StandardError, 'Generic tool error')

        expect(Otto.logger).to receive(:error)
          .with(/\[MCP\] Failed to parse TOOL route: .* - Generic tool error/)

        app.send(:handle_tool_route, 'POST', '/test', 'TOOL test TestTool.test')
      end
    end

    context 'debug logging consistency' do
      before do
        Otto.debug = true
        allow(Otto::MCP::RouteParser).to receive(:parse_mcp_route).and_return({ type: :mcp_resource })
        allow(Otto::MCP::RouteParser).to receive(:parse_tool_route).and_return({ type: :mcp_tool })
        allow(app.instance_variable_get(:@mcp_server)).to receive(:register_mcp_route)
      end

      after do
        Otto.debug = false
      end

      it 'uses consistent debug message format for MCP routes' do
        definition = 'MCP users/profile UserHandler.profile'

        expect(Otto.logger).to receive(:debug)
          .with("[MCP] Registered resource route: #{definition}")

        app.send(:handle_mcp_route, 'GET', '/users', definition)
      end

      it 'uses consistent debug message format for TOOL routes' do
        definition = 'TOOL email_sender EmailTool.send_email'

        expect(Otto.logger).to receive(:debug)
          .with("[MCP] Registered tool route: #{definition}")

        app.send(:handle_tool_route, 'POST', '/tools', definition)
      end
    end
  end
end
