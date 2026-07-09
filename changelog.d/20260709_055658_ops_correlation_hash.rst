Added
-----

- IP privacy: stable-keyed correlation hash of the full client IP, computed
  pre-masking and exposed as ``req.ip_correlation_hash`` /
  ``env['otto.privacy.correlation_hash']``. Unlike the daily-rotating
  ``hashed_ip``, it is keyed with a caller-configured stable secret
  (``configure_ip_privacy(correlation_secret:)``), so the same host correlates
  across days for long-lived records — without the raw IP ever reaching the
  app. Returns ``nil`` when privacy is disabled or no secret is configured.
  (#192)
