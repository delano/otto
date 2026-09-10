Added
-----

- ``Otto#mount_static(prefix, root:)`` registers an explicit static mount that
  serves the files under one directory at a URL prefix. Roots are canonicalized
  and validated when registered, so a missing, unreadable, non-directory, or
  unresolvable root fails at boot; each mount serves only files inside its own
  root and never exposes the root's parent or siblings. Mounts are immutable
  after configuration freezing and are read without locks at dispatch.
  Precedence is fixed: literal routes, then mounts (longest prefix first), then
  the ``public:`` directory, then dynamic routes. Applications that do not call
  ``mount_static`` are unaffected. See the static files section of
  ``docs/guides/routing.md``. (#267)

Documentation
-------------

- Documented static-file dispatch precedence, the containment policy shared by
  the ``public:`` directory and explicit mounts, and migration guidance for
  callers of the removed ``add_static_path``. Corrected the configuration
  freezing guide, which still described the ``routes_static`` cache removed in
  v2.10.0. (#267)
