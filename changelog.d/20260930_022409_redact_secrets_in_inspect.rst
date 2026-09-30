Security
--------

- ``#inspect`` no longer prints secrets held by Otto objects. Ruby's
  ``FrozenError`` message embeds the receiver's ``#inspect``, and Otto's error
  handler logs ``error.message``, so a write to a frozen
  ``Otto::Security::Config`` (for example ``config.max_request_size = 1``
  after the configuration froze) logged the CSRF signing key. These values
  now print as ``[REDACTED]``, or ``[REDACTED] (N)`` for a collection of N:

  - ``@csrf_secret`` in ``Otto::Security::Config``
  - ``@correlation_secret`` in ``Otto::Privacy::Config`` (``nil`` stays
    ``nil``)
  - ``@tokens`` in ``Otto::MCP::Auth::TokenAuth``
  - ``@auth_tokens`` in ``Otto::MCP::Server``
  - the ``auth_tokens`` and ``mcp_auth_tokens`` entries of ``@option`` in
    ``Otto#inspect``

  The output otherwise keeps the ``Object#inspect`` shape. The shared
  implementation is ``Otto::Core::RedactedInspect``.
