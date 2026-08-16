Added
-----

- Opt-in ASN resolution: ``req.asn`` / ``env['otto.privacy.asn']`` resolves
  the client's network operator (``'AS15169'``) from a local MaxMind-format
  database configured via ``configure_ip_privacy(asn: true, asn_db_path:
  ...)`` (or a bring-your-own ``asn_db_reader``). Database-only — no header
  tier exists, so the ``geo_header``/``trusted_proxy_depth`` conflict
  machinery does not apply — and the lookup uses the already-masked IP, which
  is safe because IPv4 BGP routes are not announced longer than /24. Off by
  default: ``nil`` when disabled, ``'**'`` when enabled but unresolved.

- Opt-in anonymizer classification: ``req.anonymizer`` /
  ``env['otto.privacy.anonymizer']`` labels the client address as ``'tor'``,
  ``'proxy'``, ``'vpn'``, ``'residential_proxy'``, ``'hosting'``,
  ``'anonymous'``, ``'none'`` (consulted, not listed), or ``'**'`` (no
  answer), from a local anonymous-IP database
  (``configure_ip_privacy(anonymizer: true, anonymizer_db_path: ...)``).
  This is the one database lookup performed on the UNMASKED address:
  anonymizer data lists individual egress nodes at or near /32, so a masked
  lookup would answer for the node's neighbours — flagging innocent
  addresses and missing actual exit nodes. Only the label ever leaves the
  resolver, the same containment contract as ``hash_ip`` and
  ``env['otto.ip_match']``. Off by default.

Documentation
-------------

- New ``docs/enrichment.md`` covering both signals, including the corrected
  dataset guidance: ``geo-whois-asn-country`` is a country database (the
  ``asn`` in its name describes its data *sources*, not its record
  contents); deployments wanting ASN data need a separate ASN file, e.g.
  sapics ``origin-asn`` (PDDL, rebuilt daily) — verified against the
  published file, whose records carry a flat ``autonomous_system_number``.
