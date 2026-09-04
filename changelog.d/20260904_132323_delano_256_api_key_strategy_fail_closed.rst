Changed
-------

- ``api_keys:`` is now a required keyword on
  ``Otto::Security::Authentication::Strategies::APIKeyStrategy``, and
  ``APIKeyStrategy.new`` without keys raises ``ArgumentError``. To migrate, pass
  the configured keys explicitly, e.g.
  ``APIKeyStrategy.new(api_keys: ENV.fetch('API_KEYS').split(','))``. (#256)

- ``APIKeyStrategy`` no longer places the presented key in the authentication
  result. Callers that read ``user[:api_key]`` should read
  ``user[:api_key_fingerprint]`` instead, which is a truncated SHA-256 digest of
  the key rather than the key itself. (#256)

- ``APIKeyStrategy`` no longer reads the ``api_key`` query or form parameter by
  default; only the configured header is consulted. To keep accepting
  query-string keys, pass the parameter name explicitly, e.g.
  ``APIKeyStrategy.new(api_keys: keys, param_name: 'api_key')``. (#256)

Security
--------

- ``APIKeyStrategy`` now fails closed. Previously, when no keys were
  configured, the strategy authenticated any request carrying a non-empty
  ``X-API-Key`` header or ``api_key`` parameter, so a misconfigured or
  partially configured deployment granted access to any caller that invented a
  key. The constructor now raises ``ArgumentError`` when the normalized key
  list is empty (``nil``, ``[]``, or only blank strings), a credential is
  accepted only when it matches a configured key under constant-time
  comparison, empty-string credentials are rejected, and a presented key that
  is rejected produces a terminal failure so it can no longer fall through to a
  later strategy in a multi-strategy OR chain. Non-string credentials, such as
  an ``?api_key[]=`` array query parameter, are now rejected as invalid instead
  of raising inside the constant-time comparison. (#256)

- ``APIKeyStrategy`` no longer leaks the credential into the authentication
  result. Previously the raw key was returned in both the user hash and the
  result metadata, from where it flowed into the Rack environment, the session,
  and any log line that recorded the authenticated user. The result now carries
  only a truncated SHA-256 fingerprint of the key, which is enough to correlate
  requests in an audit trail but cannot be replayed. (#256)

- ``APIKeyStrategy`` no longer accepts a key from the query or form parameter
  unless ``param_name:`` is set. A credential placed in a URL is recorded by
  access logs, proxies, and browser history, so the header is now the only
  default transport. (#256)
