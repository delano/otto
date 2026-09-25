.. A new scriv changelog fragment.
..
.. Uncomment the section that is right (remove the leading dots).
.. For top level release notes, leave all the headers commented out.
..
.. Added
.. -----
..
.. - A bullet item for the Added category.
..
Changed
-------

- Trusted-proxy settings now live in ``Otto::Security::TrustedProxyConfig``,
  which owns the rules keeping filter, depth, and trust-nobody modes mutually
  exclusive. ``Otto::Security::Config`` delegates to it, and it is readable
  through ``Config#trusted_proxy_config`` (``#mode`` returns ``:filter``,
  ``:depth``, ``:none``, or nil). The public trusted-proxy methods and
  constants on ``Config`` are unchanged; behavior is unchanged. (#148)

- ``Security::Configurator#configure`` takes ``**options`` resolved against
  ``CONFIGURE_DEFAULTS``, so adding a security option no longer grows its
  parameter list. Accepted keys, defaults, and the ``ArgumentError`` for an
  unknown key are unchanged. The RuboCop ``Metrics/ParameterLists`` ceiling
  drops from 11 to 7. (#148)
..
.. Deprecated
.. ----------
..
.. - A bullet item for the Deprecated category.
..
.. Removed
.. -------
..
.. - A bullet item for the Removed category.
..
.. Fixed
.. -----
..
.. - A bullet item for the Fixed category.
..
.. Security
.. --------
..
.. - A bullet item for the Security category.
..
.. Documentation
.. -------------
..
.. - A bullet item for the Documentation category.
..
AI Assistance
-------------

- Refactor implemented with AI assistance, checked by a differential run of
  1,620 trusted-proxy operation sequences and 29 ``configure`` calls against
  the previous release with no difference in outcome. (#148)
