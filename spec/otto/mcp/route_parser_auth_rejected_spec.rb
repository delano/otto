# spec/otto/mcp/route_parser_auth_rejected_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# MCP and TOOL route definitions are registered with the MCP server, which
# never runs the route-level auth, role or CSRF checks that normal routes get.
# A route file that puts auth=, role= or csrf= on one of these lines must fail
# to load instead of registering a handler any MCP caller can reach.
RSpec.describe Otto::MCP::RouteParser do
  include_context 'with rack attack isolation'

  before do
    stub_const('MCPRouteAuthRejectedApp', Module.new do
      def self.delete_all(_arguments, _env)
        'deleted everything'
      end

      def self.users
        'users'
      end
    end)
  end

  def load_mcp_routes(*lines)
    Otto.new(create_test_routes_file('mcp_routes.txt', lines),
      mcp_enabled: true,
      mcp_allow_unauthenticated: true)
  end

  describe 'loading a routes file' do
    it 'raises for a TOOL route with auth=' do
      expect do
        load_mcp_routes('POST /_x TOOL delete_all MCPRouteAuthRejectedApp.delete_all auth=role:admin')
      end.to raise_error(Otto::RouteDefinitionError) { |error|
        expect(error.message).to include('TOOL route "delete_all"')
        expect(error.message).to include('"auth=role:admin"')
        expect(error.message).to include('not enforced on MCP or TOOL routes')
        expect(error.message).to include('mcp_auth_tokens')
      }
    end

    it 'raises for an MCP resource route with role=' do
      expect do
        load_mcp_routes('GET /mcp/users MCP users MCPRouteAuthRejectedApp.users role=admin')
      end.to raise_error(Otto::RouteDefinitionError, /MCP route "users".*"role=admin"/)
    end

    it 'raises for a TOOL route with csrf=' do
      expect do
        load_mcp_routes('POST /_x TOOL delete_all MCPRouteAuthRejectedApp.delete_all csrf=exempt')
      end.to raise_error(Otto::RouteDefinitionError, /TOOL route "delete_all".*"csrf=exempt"/)
    end

    %w[Auth=session ROLE=admin Csrf=exempt].each do |option|
      it "raises for #{option} regardless of the option key case" do
        expect do
          load_mcp_routes("POST /_x TOOL delete_all MCPRouteAuthRejectedApp.delete_all #{option}")
        end.to raise_error(Otto::RouteDefinitionError, /not enforced on MCP or TOOL routes/)
      end
    end

    it 'still loads MCP and TOOL routes that carry other options' do
      otto = load_mcp_routes(
        'GET /mcp/users MCP users MCPRouteAuthRejectedApp.users response=json',
        'POST /_x TOOL delete_all MCPRouteAuthRejectedApp.delete_all response=json'
      )
      registry = otto.mcp_server.protocol.registry

      expect(registry.list_resources.map { |r| r[:uri] }).to eq(['users'])
      expect(registry.list_tools.map { |t| t[:name] }).to eq(['delete_all'])
    end
  end

  # The rejection, and registration itself, happen only while a routes file
  # loads with MCP already enabled (docs/guides/mcp.md).
  describe 'when MCP is enabled relative to loading the routes file' do
    let(:auth_line) { 'POST /_x TOOL delete_all MCPRouteAuthRejectedApp.delete_all auth=session' }
    let(:plain_lines) do
      [
        'GET /mcp/users MCP users MCPRouteAuthRejectedApp.users',
        'POST /_x TOOL delete_all MCPRouteAuthRejectedApp.delete_all',
      ]
    end

    def registered(otto)
      registry = otto.mcp_server.protocol.registry
      [registry.list_resources.map { |r| r[:uri] }, registry.list_tools.map { |t| t[:name] }]
    end

    it 'raises when enable_mcp! runs before load' do
      otto = Otto.new
      otto.enable_mcp!(allow_unauthenticated: true)

      expect { otto.load(create_test_routes_file('mcp_late.txt', [auth_line])) }
        .to raise_error(Otto::RouteDefinitionError, /not enforced on MCP or TOOL routes/)
    end

    it 'registers resources and tools when enable_mcp! runs before load' do
      otto = Otto.new
      otto.enable_mcp!(allow_unauthenticated: true)
      otto.load(create_test_routes_file('mcp_late.txt', plain_lines))

      expect(registered(otto)).to eq([['users'], ['delete_all']])
    end

    it 'skips MCP and TOOL lines without raising when the file loads before MCP is enabled' do
      otto = Otto.new(create_test_routes_file('mcp_early.txt', [auth_line, *plain_lines]))
      otto.enable_mcp!(allow_unauthenticated: true)

      expect(registered(otto)).to eq([[], []])
    end
  end

  describe 'parsing a single MCP or TOOL definition' do
    it 'raises from parse_tool_route' do
      expect do
        described_class.parse_tool_route('POST', '/_x', 'TOOL search App.search auth=session')
      end.to raise_error(Otto::RouteDefinitionError, /TOOL route "search"/)
    end

    it 'raises from parse_mcp_route' do
      expect do
        described_class.parse_mcp_route('GET', '/docs', 'MCP /docs App.docs role=admin')
      end.to raise_error(Otto::RouteDefinitionError, /MCP route "docs"/)
    end

    it 'keeps other options' do
      result = described_class.parse_tool_route('POST', '/_x', 'TOOL search App.search response=json')

      expect(result[:options]).to eq(response: 'json')
    end
  end
end
