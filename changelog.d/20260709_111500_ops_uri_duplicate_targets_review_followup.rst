Fixed
-----

- Addressed PR review follow-up on the #190 duplicate-target fix. Loading a
  duplicate route definition now logs at ``:debug`` instead of ``:warn`` --
  mounting one handler at several paths is a fully supported pattern, so
  warning on every boot made valid configurations (e.g. ``/users/:id`` and
  ``/me`` aliases) look unhealthy.
- ``Otto#uri``'s candidate selection no longer excludes a wildcard (``*``)
  route from the "satisfied" pool just because its synthetic ``splat`` key
  isn't among the caller's params -- ``splat`` isn't something callers ever
  pass by name, so requiring it always disqualified wildcard routes sharing
  a definition with a named-param route.
