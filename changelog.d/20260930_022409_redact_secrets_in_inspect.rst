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
  - the ``auth_tokens`` and ``mcp_auth_tokens`` entries of ``Otto#option``

  The output otherwise keeps the ``Object#inspect`` shape. The shared
  implementation is ``Otto::Core::RedactedInspect``.

- ``Otto#option`` is now an ``Otto::Core::OptionHash``, a ``Hash`` subclass.
  It stores MCP bearer tokens as ``Otto::Core::RedactedInspect::SecretList``
  (an ``Array`` subclass) of ``SecretString`` (a ``String`` subclass), or as
  a ``SecretString`` for a single token, and the MCP server and
  ``TokenAuth`` keep their own copies of the same kind. Writing to the frozen
  option Hash, to its token list or to one token (``otto.option[:x] = 1``,
  ``otto.option[:mcp_auth_tokens] << 'y'``) raises a ``FrozenError`` whose
  message shows ``[REDACTED]`` instead of the tokens. The values still are a
  ``Hash``, an ``Array`` and ``String``\ s: ``==``, ``include?``,
  iteration and ``to_s`` behave as before. ``otto.option[:mcp_auth_tokens]``
  is a copy, so the Array passed to ``Otto.new`` is no longer frozen with the
  configuration.
