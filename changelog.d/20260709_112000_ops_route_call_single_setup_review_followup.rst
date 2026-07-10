Fixed
-----

- Addressed PR review follow-up on the #189 single-setup fix. The legacy
  no-factory fallback path in ``Route#call`` now builds the request/response
  pair *before* populating the ``otto.security_config`` /
  ``otto.route_definition`` / ``otto.route_options`` env keys, restoring the
  exact ordering it always had. A prior revision set those env keys first
  regardless of which path ran, which meant a custom
  ``request_class``/``response_class#initialize`` that reads env would see
  different state on the legacy path than it did before #189.
