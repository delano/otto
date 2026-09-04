Security
--------

- Prevent static-file symlink escapes from the public directory (#257).
  ``safe_file?``/``safe_dir?`` compared lexically expanded paths, so a symlink
  under the public root could point at a same-user or same-group file outside
  it and still be served (HTTP 200). Containment is now decided on canonical
  ``File.realpath`` paths with a separator-aware prefix check: a symlink is
  served only when its fully resolved target -- including every intermediate
  directory component -- stays inside the canonical root. Missing, unreadable,
  looping and non-directory components fail closed. A symlinked public root
  (the usual ``public -> releases/<n>/public`` deploy layout) still works.

- Re-check containment on cached static routes (#257). ``routes_static``
  caches the *directory* of an approved file, and a cache hit previously
  skipped ``safe_file?`` entirely, authorizing every sibling of an
  already-served asset. The cache is now only a dispatch-ordering hint, and it
  is keyed on the canonical directory of a validated file instead of the raw
  request path (which let ``.`` segments mint unbounded keys). Static
  responses are served from the validated canonical path: ``Rack::Files`` is
  rooted at the canonical public directory and ``PATH_INFO`` is rewritten to
  the canonical relative path, so neither the root nor the path below it is
  traversed through a symlink at open time. NUL bytes in a request path are
  rejected rather than stripped.
