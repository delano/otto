Fixed
-----

- An app with MCP bearer tokens (``mcp_auth_tokens``) or MCP rate limiting no
  longer fails every request once its configuration is frozen. Freezing the
  middleware stack reached the already frozen security config a second time,
  through the arguments of ``Otto::MCP::Auth::TokenMiddleware`` and
  ``Otto::MCP::RateLimitMiddleware``. ``Otto::Security::Config#deep_freeze!``
  then reran its freeze-time validators and raised ``FrozenError``. Because
  the lazy freeze in ``Otto#call`` never completed, every later request
  retried it and raised again; an explicit ``freeze_configuration!`` at boot
  raised the same error. ``Config#deep_freeze!`` now returns ``self`` when the
  config is already frozen, as ``Otto::Core::Freezable#deep_freeze!`` does.
  The test suite did not catch this because ``Otto#call`` skips the lazy
  freeze when RSpec is loaded.
