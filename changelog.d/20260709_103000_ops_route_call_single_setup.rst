Fixed
-----

- ``Route#call`` no longer builds and decorates a request/response pair that
  is immediately discarded when the route handler factory is present (#189).
  The handler (``BaseHandler#setup_request_response``) now owns all
  request/response construction and setup — param merging, indifferent
  access, security headers, CSRF/validation helpers each run exactly once
  per dispatch instead of twice on different objects. ``Route#call`` only
  sets the env keys that must be visible before the handler runs
  (``otto.security_config``, ``otto.route_definition``,
  ``otto.route_options``). The legacy no-factory path is unchanged.
