Changed
-------

- Literal routes now consistently take precedence over static files at the same
  path, regardless of which static files were requested earlier. Static files
  continue to take precedence over dynamic routes. (#260)

Removed
-------

- Removed ``add_static_path`` and the ``routes_static`` cache interface. Static
  files are discovered directly from the configured ``public`` directory and
  no longer need registration. (#260)
