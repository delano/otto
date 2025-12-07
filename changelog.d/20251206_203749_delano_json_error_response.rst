.. A new scriv changelog fragment.
..
.. Uncomment the section that is right (remove the leading dots).
.. For top level release notes, leave all the headers commented out.
..
Added
-----

- Base HTTP error classes (``Otto::NotFoundError``, ``Otto::BadRequestError``, ``Otto::ForbiddenError``, ``Otto::UnauthorizedError``, ``Otto::PayloadTooLargeError``) that implementing projects can subclass for consistent error handling
- Auto-registration of all framework error classes during ``Otto#initialize`` - framework errors now automatically return correct HTTP status codes without manual registration

Changed
-------

- Framework error classes now inherit from new base classes: ``Otto::Security::AuthorizationError`` < ``Otto::ForbiddenError``, ``Otto::Security::CSRFError`` < ``Otto::ForbiddenError``, ``Otto::Security::RequestTooLargeError`` < ``Otto::PayloadTooLargeError``, ``Otto::Security::ValidationError`` < ``Otto::BadRequestError``, ``Otto::MCP::ValidationError`` < ``Otto::BadRequestError``
- ``Otto::Security::RequestTooLargeError`` now returns HTTP 413 (Payload Too Large) instead of 500, semantically correct per RFC 7231

AI Assistance
-------------

- Implementation design and architecture developed with AI pair programming
- Comprehensive test coverage (31 new base class tests, 12 auto-registration tests) developed with AI assistance
- Error class hierarchy and inheritance patterns refined through AI-guided architectural discussion
