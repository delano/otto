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

- Serve static responses from the validated canonical path (#257).
  ``Rack::Files`` is rooted at the canonical public directory and receives the
  canonical relative path, so neither the root nor the path below it is
  traversed through a symlink at open time. NUL bytes in a request path are
  rejected rather than stripped.
