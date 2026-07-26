Fixed
-----

- ``Otto::Request#secure?`` now honors ``env['rack.url_scheme']`` — the
  canonical Rack scheme key that ``Rack::Request#scheme``/``#ssl?`` (and
  therefore the session Secure-cookie gate, ``Rack::Protection``, and Otto's
  own CSRF middleware) read. An upstream middleware that normalizes the scheme
  the idiomatic Rack way (setting only ``rack.url_scheme = 'https'``) is now
  visible to ``secure?`` instead of producing a second, divergent scheme-truth.
  The key is server-/middleware-set, never a client header, so it is treated as
  authoritative; the trusted-proxy gate on the raw ``X-Forwarded-Proto`` /
  ``X-Scheme`` headers is unchanged. (#214)

AI Assistance
-------------

- Divergence analysis, fix, and regression specs written with AI assistance.
  (#214)
