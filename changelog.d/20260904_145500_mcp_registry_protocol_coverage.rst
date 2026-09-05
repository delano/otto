Fixed
-----

- MCP JSON-RPC errors now consistently use HTTP 400 for protocol errors, 404
  for unknown resources or tools, and 500 for handler or server failures.
  Unknown tools no longer return 500, failing resource handlers no longer
  appear missing, and handler exception details are logged instead of returned
  to clients. (#257)
