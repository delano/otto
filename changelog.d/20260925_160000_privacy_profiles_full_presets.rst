Fixed
-----

- ``Otto::Privacy::Config#profile=`` now sets both ``disabled`` and
  ``mask_private_ips`` for every profile. ``:audit`` previously set only
  ``disabled``, so switching ``:anonymous`` to ``:audit`` left
  ``mask_private_ips`` true, and a later ``enable!`` restored
  ``:anonymous`` instead of ``:masked``. ``:audit`` now sets
  ``mask_private_ips: false``, the same value ``Config.new(profile: :audit)``
  already produced.
