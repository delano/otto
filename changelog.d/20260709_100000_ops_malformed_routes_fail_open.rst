Security
--------

- Route loading no longer fails open on malformed input (#191). A route line
  with a missing handler and any unparseable option token now emit a warning
  unconditionally (previously silent, or gated behind ``Otto.debug``). A
  malformed security-gating option — a bare or empty ``auth``, ``role``, or
  ``csrf`` token (e.g. ``csrf exempt`` instead of ``csrf=exempt``) — now
  raises ``Otto::RouteDefinitionError`` at load so the app fails at boot
  instead of quietly serving the route without its intended protection.
