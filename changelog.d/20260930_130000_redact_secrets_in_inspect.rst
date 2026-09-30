Security
--------

- ``Otto::Security::Config#inspect`` no longer prints the CSRF signing key.
  Ruby's default ``inspect`` listed every instance variable, including
  ``@csrf_secret``, and a native ``FrozenError`` raised on a frozen config
  embeds the receiver's ``inspect`` in its message, so the key reached any log
  that recorded such an error. ``@csrf_secret`` now prints as ``[REDACTED]``.
  The same applies to ``Otto::Privacy::Config#inspect`` for
  ``@correlation_secret``. A nil value still prints as ``nil``. ``pp`` output
  uses the same redacted ``inspect``.

- ``Otto::MCP::Auth::TokenAuth#inspect`` reports a token count instead of the
  tokens, and ``Otto::MCP::Server#inspect`` reports the endpoint, enabled
  state, and token count instead of dumping its instance variables (which
  included the raw ``auth_tokens`` and the Otto instance).

- The shared implementation is ``Otto::Core::RedactedInspect``. It writes no
  state to the receiver, so it is safe on a frozen instance.
