Security
--------

- Closed two gaps left by the #191 fail-fast fix (PR review follow-up).
  Security-gating option tokens with mismatched case (e.g. ``Auth=session``,
  ``CSRF=exempt``) previously slipped past the check and were stored as an
  unrecognized option, silently disabling the gate; they now raise
  ``Otto::RouteDefinitionError`` like any other malformed security option.
  A token with an empty key (e.g. ``=foo``) previously stored an empty-symbol
  option silently; it now emits the same "malformed route option ignored"
  warning as other unparseable tokens.
- MCP and TOOL route handler definitions (``MCP ...`` / ``TOOL ...`` route
  lines) now apply the same fail-fast validation: a bare or malformed
  ``auth``, ``role``, or ``csrf`` token in the handler definition raises
  ``Otto::RouteDefinitionError`` instead of silently registering the route
  without its intended protection.
