Fixed
-----

- Locale middleware now tries exact region match (``fr-FR`` → ``fr_FR``) before falling back to primary language code, fixing locale resolution for region-qualified ``available_locales`` entries (#117)

Added
-----

- Optional ``fallback_locale`` configuration for ``Otto::Locale::Middleware`` and ``Locale::Config``, enabling custom locale fallback chains between exact region match and primary code resolution
