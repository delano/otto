# spec/support/mcp_modern_helpers.rb
#
# frozen_string_literal: true

# Builds and sends requests in the shape MCP revision 2026-07-28 requires:
# the protocol version and client capabilities in params._meta, and the
# version, the method and the tool name or resource URI repeated in headers.
#
#   include_context 'with mcp 2026-07-28 requests'
RSpec.shared_context 'with mcp 2026-07-28 requests' do
  let(:mcp_version) { '2026-07-28' }

  # @param method_name [String] JSON-RPC method
  # @param params [Hash] method parameters, without _meta
  # @param token [String, nil] sent as Authorization: Bearer
  # @param capabilities [Hash] the client capabilities to declare
  # @param headers [Hash] CGI-style env entries merged last; a nil value
  #   removes the entry
  # @param meta [Hash] _meta entries merged last; a nil value removes the entry
  # @return [Hash] Rack env
  def modern_env(method_name, params = {}, token: nil, capabilities: {}, headers: {}, meta: {}, id: 1, path: '/mcp') # rubocop:disable Metrics/ParameterLists -- a keyword-only request builder
    request_meta = {
      'io.modelcontextprotocol/protocolVersion' => mcp_version,
      'io.modelcontextprotocol/clientCapabilities' => capabilities,
    }.merge(meta).compact
    body = JSON.generate({ jsonrpc: '2.0', id: id, method: method_name, params: params.merge('_meta' => request_meta) })

    env = Rack::MockRequest.env_for(path, method: 'POST', input: body, 'CONTENT_TYPE' => 'application/json')
    env['HTTP_MCP_PROTOCOL_VERSION'] = mcp_version
    env['HTTP_MCP_METHOD']           = method_name
    env['HTTP_MCP_NAME']             = params['name'] || params['uri'] if params['name'] || params['uri']
    env['HTTP_AUTHORIZATION']        = "Bearer #{token}" if token
    headers.each { |key, value| value.nil? ? env.delete(key) : env[key] = value }
    env
  end

  # @return [Array] status, response headers, parsed body (nil when empty)
  def modern_call(app, method_name, params = {}, **)
    status, headers, body = app.call(modern_env(method_name, params, **))
    text                  = body.to_a.join
    [status, headers, text.empty? ? nil : JSON.parse(text)]
  end
end
