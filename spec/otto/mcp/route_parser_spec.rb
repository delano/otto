# spec/otto/mcp/route_parser_spec.rb
#
# frozen_string_literal: true

require_relative '../../spec_helper'

RSpec.describe Otto::MCP::RouteParser, 'MCP and TOOL route definitions' do
  describe '.is_mcp_route? / .is_tool_route?' do
    it 'detects the leading keyword' do
      expect(described_class.is_mcp_route?('MCP /docs App.docs')).to be true
      expect(described_class.is_mcp_route?('TOOL search App.search')).to be false
      expect(described_class.is_tool_route?('TOOL search App.search')).to be true
      expect(described_class.is_tool_route?('GET / App.index')).to be false
    end
  end

  describe '.parse_mcp_route' do
    it 'parses a plain resource line and strips the leading slash' do
      expect(described_class.parse_mcp_route('MCP', '/', 'MCP /docs/readme App.readme')).to eq(
        type: :mcp_resource,
        resource_uri: 'docs/readme',
        handler: 'App.readme',
        options: {}
      )
    end

    it 'carries option tokens through to :options' do
      result = described_class.parse_mcp_route('MCP', '/', 'MCP docs App.readme response=json')

      expect(result[:handler]).to eq('App.readme response=json')
      expect(result[:options]).to eq(response: 'json')
    end

    it 'rejects auth, role and csrf option tokens' do
      expect { described_class.parse_mcp_route('MCP', '/', 'MCP docs App.readme auth=role:admin') }
        .to raise_error(Otto::RouteDefinitionError, /not enforced on MCP or TOOL routes/)
    end

    it 'raises on a malformed line missing the handler' do
      expect { described_class.parse_mcp_route('MCP', '/', 'MCP docs') }
        .to raise_error(ArgumentError, /Invalid MCP route format/)
    end

    it 'raises when the keyword is not MCP' do
      expect { described_class.parse_mcp_route('MCP', '/', 'TOOL docs App.readme') }
        .to raise_error(ArgumentError, /Expected MCP keyword/)
    end
  end

  # Nothing reads the options of an MCP or TOOL route, so a well-formed option
  # other than auth/role/csrf still loads but is reported as not applied.
  describe 'options that are not applied' do
    before { allow(Otto).to receive(:structured_log) }

    it 'warns for each option on a TOOL line' do
      described_class.parse_tool_route('TOOL', '/', 'TOOL search App.search response=json scope=canonical')

      %w[response=json scope=canonical].each do |option|
        expect(Otto).to have_received(:structured_log)
          .with(:warn, 'MCP/tool route option not applied', { option: option, route: 'TOOL route "search"' })
      end
    end

    it 'warns for an option on an MCP line' do
      described_class.parse_mcp_route('MCP', '/', 'MCP docs App.readme response=json')

      expect(Otto).to have_received(:structured_log)
        .with(:warn, 'MCP/tool route option not applied', { option: 'response=json', route: 'MCP route "docs"' })
    end

    it 'does not warn for a line without options' do
      described_class.parse_tool_route('TOOL', '/', 'TOOL search App.search')

      expect(Otto).not_to have_received(:structured_log)
    end
  end

  describe '.parse_tool_route' do
    it 'parses a plain tool line and strips the leading slash' do
      expect(described_class.parse_tool_route('TOOL', '/', 'TOOL /search App.search')).to eq(
        type: :mcp_tool,
        tool_name: 'search',
        handler: 'App.search',
        options: {}
      )
    end

    it 'carries option tokens through to :options' do
      result = described_class.parse_tool_route('TOOL', '/', 'TOOL search App.search response=json')

      expect(result[:options]).to eq(response: 'json')
    end

    it 'rejects auth, role and csrf option tokens' do
      expect { described_class.parse_tool_route('TOOL', '/', 'TOOL search App.search auth=role:admin') }
        .to raise_error(Otto::RouteDefinitionError, /not enforced on MCP or TOOL routes/)
    end

    it 'raises on a malformed line missing the handler' do
      expect { described_class.parse_tool_route('TOOL', '/', 'TOOL search') }
        .to raise_error(ArgumentError, /Invalid TOOL route format/)
    end

    it 'raises when the keyword is not TOOL' do
      expect { described_class.parse_tool_route('TOOL', '/', 'MCP search App.search') }
        .to raise_error(ArgumentError, /Expected TOOL keyword/)
    end
  end
end
