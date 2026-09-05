Security
--------

- When proxy trust is configured, forwarded host, scheme, and port metadata
  from untrusted peers is now stripped before it can affect Rack's request
  authority. Requests from trusted peers retain this metadata; see
  ``docs/guides/forwarded-authority.md`` for deployment guidance. (#252)

Changed
-------

- Otto applications in one process that resolve proxied requests must now use
  the same forwarded-header family; incompatible configurations fail during
  configuration. CIDR-based proxy trust supports only ``X-Forwarded-*`` headers; use
  depth-based trust for ``Forwarded`` or both families. See
  ``docs/guides/forwarded-authority.md`` for configuration guidance. (#252)
