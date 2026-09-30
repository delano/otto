Security
--------

- ``#inspect`` no longer prints secrets held by Otto objects. Ruby's
  ``FrozenError`` message embeds the receiver's ``#inspect``, and Otto's error
  handler logs ``error.message``, so a write to a frozen
  ``Otto::Security::Config`` (for example ``config.max_request_size = 1``
  after the configuration froze) logged the CSRF signing key. These values
  now print as ``[REDACTED]``, or ``[REDACTED] (N)`` for a collection of N,
  in ``#inspect`` and in ``pp``:

  - ``@csrf_secret`` in ``Otto::Security::Config``
  - ``@correlation_secret`` in ``Otto::Privacy::Config`` (``nil`` stays
    ``nil``)
  - ``@tokens`` in ``Otto::MCP::Auth::TokenAuth``
  - ``@auth_tokens`` in ``Otto::MCP::Server``
  - the ``auth_tokens`` and ``mcp_auth_tokens`` entries of ``Otto#option``

  The output otherwise keeps the ``Object#inspect`` shape. The shared
  implementation is ``Otto::Core::RedactedInspect``. (#300)

- ``Otto#option`` is now an ``Otto::Core::OptionHash``, a ``Hash`` subclass.
  It stores MCP bearer tokens as ``Otto::Core::RedactedInspect::SecretList``
  (an ``Array`` subclass) or ``SecretSet`` (a ``Set`` subclass) of frozen
  ``SecretString`` copies (a ``String`` subclass), or as one frozen
  ``SecretString`` for a single token, including tokens assigned with
  ``[]=`` or ``store`` after construction. The MCP server builds its own
  ``SecretList``, and ``TokenAuth`` a frozen ``SecretSet`` holding the same
  frozen ``SecretString`` objects as the server; ``Otto#option`` holds
  separate copies. Writing to the frozen option Hash, to its token list or
  Set, or to one token (``otto.option[:x] = 1``,
  ``otto.option[:mcp_auth_tokens] << 'y'``) raises a ``FrozenError`` whose
  message shows ``[REDACTED]`` instead of the tokens. The values are still a
  ``Hash``, an ``Array`` or ``Set``, and ``String``\ s: ``==``, ``include?``
  and iteration behave as before. ``to_s`` of the option Hash, of a token
  list and of a token Set now returns the redacted text, for example
  ``[REDACTED] (1)``; ``to_s`` of one token still returns the token.
  ``otto.option[:mcp_auth_tokens]`` is a copy, so the Array or Set passed to
  ``Otto.new`` is no longer frozen with the configuration. (#300)

- With ``Otto.debug`` on, ``Otto.new`` logged its raw options, including
  ``mcp_auth_tokens``. It now logs the redacted ``Otto#option``. (#300)

- ``Otto::Privacy::Config#correlation_secret`` returns a frozen
  ``SecretString`` copy of the configured value, and
  ``Otto::Security::Config#deep_freeze!`` replaces the CSRF signing key with
  a frozen ``SecretString`` copy before it freezes the config. Neither freezes
  the String the application passed in, so a later write to that String no
  longer raises a ``FrozenError`` that prints it, and a write through
  ``correlation_secret`` raises one that shows ``[REDACTED]``. (#300)
