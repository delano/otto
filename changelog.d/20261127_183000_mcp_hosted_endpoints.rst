Added
-----

- ``Otto#register_mcp_tool`` registers an MCP tool together with the JSON
  Schemas Otto enforces for it. Arguments are checked against
  ``input_schema`` before the handler runs, and a call that fails the check
  returns a tool result with ``isError: true`` that names each location and
  rule without the value. When ``output_schema`` is given, the handler's
  return value is checked before it is sent and is returned as
  ``structuredContent``; a value that does not conform is withheld and the
  call fails with a JSON-RPC internal error. Otto adds
  ``additionalProperties: false`` to the root of an input schema that does
  not set it. A handler raises ``Otto::MCP::ToolError`` to return a failure
  the model can read. ``Otto#register_mcp_resource`` registers a resource
  from Ruby. Both need ``json_schemer`` and must be called before the first
  request.

- The ``authenticator:`` MCP option (``mcp_authenticator:`` on ``Otto.new``)
  takes an object that responds to ``call(token, env)``. Otto reads the token
  from ``Authorization: Bearer`` and from no other header or query parameter,
  and the authenticator returns an ``Otto::MCP::Auth::Context`` (subject,
  client ID, tenant, scopes, audience and optionally issuer) for a token it
  accepts. The context is stored in ``env['otto.mcp.auth']``. A refused
  request gets ``401`` with a ``WWW-Authenticate: Bearer`` challenge.
  ``authenticator:`` and ``auth_tokens:`` cannot be combined. When the
  authenticator raises, Otto raises ``Otto::MCP::AuthenticatorError`` in its
  place, with the original's class and backtrace and without its message,
  which could quote the token.

- ``scopes:`` on a declared tool or resource lists the OAuth scopes a caller
  needs. ``tools/list`` and ``resources/list`` return only what the caller's
  scopes cover, and ``tools/call`` and ``resources/read`` check the scopes
  again whatever the lists returned. A caller who lacks a scope gets ``403``
  with an ``insufficient_scope`` challenge that names the scopes. Registering
  a tool or resource with scopes on an endpoint that has no authenticator
  raises ``ArgumentError``. A declared tool, and a resource that requires
  scopes, cannot be replaced: a ``TOOL`` or ``MCP`` route line that names one
  raises ``Otto::RouteDefinitionError``.

- The ``protocol_versions:`` MCP option selects the revisions an endpoint
  serves: ``2024-11-05`` (the default, and the only one before this release),
  ``2026-07-28``, or both. Under ``2026-07-28`` Otto serves
  ``server/discover``, ``tools/list``, ``tools/call``, ``resources/list`` and
  ``resources/read`` without an ``initialize`` handshake; requires the
  ``MCP-Protocol-Version``, ``Mcp-Method`` and ``Mcp-Name`` headers to match
  the request body; adds ``resultType``, the server's name and version, and
  caching hints to results; and answers ``GET`` and ``DELETE`` on the
  endpoint with ``405``. ``server_info:``, ``instructions:`` and
  ``cache_ttl_ms:`` set what those results report. Prompts,
  ``subscriptions/listen``, streamed responses, pagination cursors and
  ``x-mcp-header`` are not implemented.

- A tool handler can return ``Otto::MCP::InputRequired.url`` to send the
  person at the MCP client to a page, for input that must not pass through
  the client or the model. Under ``2026-07-28`` Otto answers the call with a
  URL elicitation request and an encrypted ``requestState`` that opens only
  for the same issuer, subject, client and tenant repeating the same call
  with the same arguments at the same endpoint before it expires. The
  handler reads the verified state, the
  caller and the client's declared capabilities from
  ``env['otto.mcp.call']``. Otto sends the request only to a verified caller
  whose client declared URL elicitation. ``request_state_secret:`` sets the
  key material; without it each process generates its own.

- The ``hosted: true`` MCP option makes the application refuse to boot unless
  the endpoint has an authenticator, a ``resource_uri:`` and
  ``authorization_servers:``, serves ``2026-07-28`` only, and takes every tool
  and resource from ``register_mcp_tool`` and ``register_mcp_resource`` with
  ``scopes:`` stated and, for tools, ``output_schema:`` stated. ``MCP`` and
  ``TOOL`` route lines raise ``Otto::RouteDefinitionError`` on such an
  endpoint, and enabling it raises if a tool or resource was registered
  first.

- ``Otto.new`` reads the options added in this release only under their
  ``mcp_`` spelling (``mcp_hosted:``, ``mcp_authenticator:`` and so on).
  ``enable_mcp!`` accepts both spellings. A bare ``hosted:`` or
  ``instructions:`` in the hash given to ``Otto.new`` stays the
  application's own.

- With ``resource_uri:`` set, Otto refuses a token whose context does not
  list that URI in its audience, and serves the OAuth protected resource
  metadata document (RFC 9728) at ``/.well-known/oauth-protected-resource``
  followed by the endpoint path. ``Otto::MCP::Server#protected_resource_metadata``
  returns the document for an application that serves it elsewhere.
  ``scopes_supported:`` sets the scopes named in the document and in the
  ``401`` challenge.

- The ``allowed_origins:`` MCP option lists the origins a browser may call
  the endpoint from. An endpoint that serves ``2026-07-28`` answers ``403``
  to a request whose ``Origin`` header is not listed, and lists none by
  default. An endpoint that serves only ``2024-11-05`` checks ``Origin`` only
  when the option is set.

Changed
-------

- When an MCP tool or resource handler raises, Otto no longer logs the
  exception's message. It logs the exception class, a code (``tool_failed``,
  ``tool_output_invalid``, ``resource_failed`` or ``input_request_unbound``),
  an ``error_id`` and a sanitized backtrace. The response is unchanged for
  ``2024-11-05``; under ``2026-07-28`` it includes the ``error_id``.

- MCP tools and resources freeze with the rest of the configuration at the
  first request. Registering or replacing one afterwards raises
  ``FrozenError``. Before this, ``Otto::MCP::Registry`` accepted
  registrations at any time.

- ``Otto::MCP::Registry#list_tools`` and ``#list_resources`` take the caller
  as an optional argument and leave out what that caller's scopes do not
  cover. Without the argument they leave out everything that requires a
  scope.

Security
--------

- A value under ``env['otto.mcp.auth']`` that the endpoint's own
  authenticator did not put there on this request is never used. The
  authentication middleware removes the key before it authenticates and
  records which authenticator produced the context, the protocol handler
  discards a context its own authenticator did not produce, and an endpoint
  with no authenticator discards the key.

- ``request_state_secret`` (in either spelling) is redacted in
  ``Otto#option`` and in the error raised for two conflicting spellings.

Documentation
-------------

- ``docs/guides/mcp.md`` covers declared tools, authenticators and scopes,
  MCP ``2026-07-28``, hosted endpoints and URL input requests, and lists the
  parts of ``2026-07-28`` Otto does not implement. Its statements about what
  MCP requires quote the specification at a pinned commit.

AI Assistance
-------------

- The MCP authenticator, declared tools, ``2026-07-28`` handler, input
  requests and hosted profile were designed and implemented with AI
  assistance from Delano's design note of 2026-11-26, against the
  ``2026-07-28`` specification text at commit ``bd5bc16`` of
  modelcontextprotocol/modelcontextprotocol. The specs include an
  end-to-end handoff with separate requester, reader and other-client
  callers, and check that neither a submitted secret nor a bearer token
  reaches a response or a log.
