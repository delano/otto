Security
--------

- ``Otto::Security::Config#csrf_secret=`` no longer uses ``nil`` or a blank
  string as the CSRF signing key. Previously ``config.csrf_secret = ''`` (for
  example from ``ENV.fetch('OTTO_CSRF_SECRET', '')``) stored the empty string
  as the HMAC key and marked the secret as configured, so the production guard
  did not fire and a token signed with an empty key verified. ``nil`` was
  stored as well, and every token signing then raised ``TypeError``. ``nil``
  and blank strings now get a fresh random per-process secret marked as
  generated, the same fallback as an unset ``OTTO_CSRF_SECRET``. With CSRF
  protection enabled and ``RACK_ENV=production``, generating a token then
  raises ``ArgumentError`` asking for a configured secret, as it does when
  ``OTTO_CSRF_SECRET`` is unset.

- A secret is blank when it holds only Unicode whitespace (``[[:space:]]``),
  NUL, zero-width spaces and joiners (U+200B to U+200D), the word joiner
  (U+2060) or the byte order mark (U+FEFF). The pattern is
  ``Otto::Security::Config::BLANK_CSRF_SECRET``, matched in UTF-8. A string
  that is not valid in its encoding, or cannot be converted to UTF-8, is blank
  only if it holds nothing but ASCII whitespace and NUL.

- A blank ``OTTO_CSRF_SECRET`` is now treated as unset, like an empty one.

- ``csrf_secret=`` raises ``ArgumentError`` for a value that is neither a
  ``String`` nor ``nil``.
