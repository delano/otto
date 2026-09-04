Security
--------

- ``APIKeyStrategy`` now requires exactly one key source and rejects empty
  static key lists at construction. Invalid presented credentials terminate a
  multi-strategy authentication chain, and static keys are compared in constant
  time. (#256)

- Successful authentication results no longer expose the raw API key in
  strategy-generated fields. Static-list callers should replace
  ``user[:api_key]`` with ``user[:api_key_fingerprint]``. (#256)

- ``APIKeyStrategy`` now reads only the configured header by default. Applications
  that still accept query or form parameters must opt in with ``param_name:``;
  see ``docs/guides/authentication.md`` for configuration guidance. (#256)
