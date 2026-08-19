Added
-----

- Add opt-in request-scoped CSP directive extras for sources that are known
  only while handling a request. Enable the feature at boot with
  ``security_config.enable_csp_request_extras!``, then add approved source
  origins by directive through ``env['otto.csp.extra_directives']``. This
  supports cases such as adding a tenant's SSO provider to ``form-action``.
  Disabled by default. (#243)

Security
--------

- Validate request-scoped CSP extras before adding them to a response policy.
  Extras can only add valid HTTP(S) origins to compatible directives already
  present in the configured policy; script and default source directives are
  excluded. Invalid or unsupported entries are ignored and logged without
  affecting the remaining policy. (#243)
