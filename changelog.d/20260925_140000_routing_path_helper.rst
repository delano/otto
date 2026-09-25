Added
-----

- ``Otto::Utils.routing_path(env)`` returns the path the router matches:
  ``PATH_INFO`` percent-decoded, with invalid UTF-8 scrubbed and one trailing
  slash stripped. The router gets its path from this method, so middleware
  that compares against it matches exactly what the router dispatches.
  ``include_mount: true`` prepends ``SCRIPT_NAME`` before normalizing, for
  middleware shared by apps mounted under different sub-paths.

Fixed
-----

- A request whose ``PATH_INFO`` has a malformed percent-escape (``%zz``) or a
  raw invalid byte no longer answers 500 with an unhandled-error log. The
  router no longer runs a second ``Rack::Utils.unescape`` of its own, which
  raised on those paths. They are now routed like any other path: a malformed
  escape is kept as written, and a raw invalid byte is scrubbed the same way
  its percent-encoded form (``%FF``) already was.

Documentation
-------------

- The routing guide covers matching request paths in middleware, including
  apps mounted under a sub-path.
