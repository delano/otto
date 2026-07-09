Added
-----

- ``Otto::Privacy::UserAgentPrivacy.anonymize(ua, max_length:)`` — a public
  User-Agent anonymization surface (the analogue of ``Otto::Privacy::IPPrivacy``
  for the User-Agent header). Strips build identifiers and version numbers and
  truncates, preserving browser/OS family text; idempotent, so re-anonymizing
  already-anonymized output is a no-op. Lets downstream consumers reduce a UA
  outside of the full RedactedFingerprint / middleware flow without
  re-implementing (and drifting from) the regexes. (delano/otto#194)

Changed
-------

- ``Otto::Privacy::RedactedFingerprint#anonymize_user_agent`` now delegates to
  ``Otto::Privacy::UserAgentPrivacy.anonymize``, making the public class the
  single source of truth for User-Agent reduction. Behavior is unchanged.
  (delano/otto#194)
