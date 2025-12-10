Added
-----

- ``Otto::Request`` and ``Otto::Response`` classes extending Rack equivalents
- ``register_request_helpers`` and ``register_response_helpers`` for application-specific helpers
- Helper modules included at class level (not per-request extension)

Changed
-------

- Moved ``lib/otto/helpers/request.rb`` → ``lib/otto/request.rb``
- Moved ``lib/otto/helpers/response.rb`` → ``lib/otto/response.rb``
- All internal code now uses ``Otto::Request``/``Otto::Response`` instead of ``Rack::Request``/``Rack::Response``
