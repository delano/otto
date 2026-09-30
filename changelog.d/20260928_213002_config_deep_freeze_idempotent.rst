Fixed
-----

- An MCP endpoint with ``auth_tokens`` (``mcp_auth_tokens``), or with MCP rate
  limiting, raised ``FrozenError`` on every request outside RSpec. The first
  request runs the lazy configuration freeze in ``Otto#call``. Freezing the
  middleware stack reached the already frozen security config a second time,
  through the arguments of ``Otto::MCP::Auth::TokenMiddleware`` and
  ``Otto::MCP::RateLimitMiddleware``, and
  ``Otto::Security::Config#deep_freeze!`` then reran its freeze-time
  validators and raised ``FrozenError: Cannot modify frozen configuration``.
  Because the freeze never completed, every later request retried it and
  raised again; an explicit ``freeze_configuration!`` at boot raised the same
  error. ``Config#deep_freeze!`` now returns ``self`` when ``deep_freeze!``
  already froze the config. On a config frozen with ``Object#freeze``, whose
  nested settings are still mutable, it raises ``FrozenError`` with
  ``Otto::Security::Config::SHALLOW_FREEZE_MESSAGE``, as main raised a
  ``FrozenError`` there too. The test suite did not catch this because
  ``Otto#call`` skips the lazy freeze when RSpec is loaded. (#293)
