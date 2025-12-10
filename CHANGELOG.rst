CHANGELOG.rst
=============

The format is based on `Keep a Changelog <https://keepachangelog.com/en/1.1.0/>`__, and this project adheres to `Semantic Versioning <https://semver.org/spec/v2.0.0.html>`__.

.. raw:: html

   <!--scriv-insert-here-->

.. _changelog-2.0.0.pre10:

2.0.0.pre10 — 2025-12-09
========================

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

.. _changelog-2.0.0.pre9:

2.0.0.pre9 — 2025-12-06
=======================

Added
-----

- Base HTTP error classes (``Otto::NotFoundError``, ``Otto::BadRequestError``, ``Otto::ForbiddenError``, ``Otto::UnauthorizedError``, ``Otto::PayloadTooLargeError``) that implementing projects can subclass for consistent error handling
- Auto-registration of all framework error classes during ``Otto#initialize`` - framework errors now automatically return correct HTTP status codes without manual registration

Changed
-------

- Framework error classes now inherit from new base classes: ``Otto::Security::AuthorizationError`` < ``Otto::ForbiddenError``, ``Otto::Security::CSRFError`` < ``Otto::ForbiddenError``, ``Otto::Security::RequestTooLargeError`` < ``Otto::PayloadTooLargeError``, ``Otto::Security::ValidationError`` < ``Otto::BadRequestError``, ``Otto::MCP::ValidationError`` < ``Otto::BadRequestError``
- ``Otto::Security::RequestTooLargeError`` now returns HTTP 413 (Payload Too Large) instead of 500, semantically correct per RFC 7231

- Consolidated route handler implementation using Template Method pattern, reducing duplication by ~120 lines while improving maintainability

Fixed
-----

- Error handlers now respect route's ``response=json`` parameter for content
  negotiation, ensuring API routes always return JSON error responses regardless
  of the Accept header.

- Rate limiters now respect route ``response=json`` declarations when returning
  throttled responses, matching the error handler fix for consistent content
  negotiation across all error paths.

- ClassMethodHandler direct testing context now respects route ``response_type``
  when generating error responses.

- Unified error handling across ClassMethodHandler and InstanceMethodHandler to consistently support JSON content negotiation

AI Assistance
-------------

- Implementation design and architecture developed with AI pair programming
- Comprehensive test coverage (31 new base class tests, 12 auto-registration tests) developed with AI assistance
- Error class hierarchy and inheritance patterns refined through AI-guided architectural discussion

.. _changelog-2.0.0.pre8:

2.0.0.pre8 — 2025-11-27
=======================

Fixed
-----

- Routes declaring ``response=json`` now return 401 JSON errors instead of 302 redirects when authentication fails, regardless of Accept header. The route's explicit configuration takes precedence over content negotiation.

.. _changelog-2.0.0.pre7:

2.0.0.pre7 — 2025-11-24
=======================

Added
-----

- Error handler registration system for expected business logic errors via ``otto.register_error_handler(ErrorClass, status:, log_level:)``. Supports custom response handlers via blocks.

Changed
-------

- Backtrace logging now always logs at ERROR level with sanitized file paths (was DEBUG level with full paths)
- Increased backtrace limit from 10 to 20 lines for better debugging context
- Improved gem path formatting in backtraces (e.g., ``[GEM] rack/lib/rack.rb:20``)

Fixed
-----

- Fixed path sanitization for bundler git-based gems and multi-hyphenated gem names

Documentation
-------------

- Documented security guarantees and sanitization rules
- Added examples showing before/after path transformations

AI Assistance
-------------

- Implemented error handler registration architecture with comprehensive test coverage (17 test cases) using sequential thinking to work through security implications and design decisions. AI assisted with path sanitization strategy, error classification patterns, and ensuring backward compatibility with existing error handling.

.. _changelog-2.0.0.pre6:

2.0.0.pre6
==========

Changed
-------

- **BREAKING**: ``Otto.on_request_complete`` is now an instance method instead of a class method. This fixes duplicate callback invocations in multi-app architectures (e.g., Rack::URLMap with multiple Otto instances). Each Otto instance now maintains its own isolated set of callbacks that only fire for requests processed by that specific instance.

  **Migration**: Change ``Otto.on_request_complete { |req, res, dur| ... }`` to ``otto.on_request_complete { |req, res, dur| ... }``

- **Logging**: Eliminated duplicate error logging in route handlers. Previously, errors produced two log lines ("Handler execution failed" + "Unhandled error in request"). Now produces a single comprehensive error log with all context (handler, duration, error_id). Lambda handlers now use centralized error handling for consistency. #86

Fixed
-----

- Fixed issue #84 where ``on_request_complete`` callbacks would fire N times per request in multi-app architectures, causing duplicate logging and metrics
- Fixed ``Otto.structured_log`` to respect ``Otto.debug`` flag - debug logs are now properly skipped when ``Otto.debug = false``

AI Assistance
-------------

- This enhancement was developed with assistance from Claude Code (Opus 4.1)

.. _changelog-2.0.0.pre5:

2.0.0.pre5 — 2025-10-21
=======================

Added
-----

- Added ``Otto::LoggingHelpers.log_timed_operation`` for automatic timing and error handling of operations
- Added ``Otto::LoggingHelpers.log_backtrace`` for consistent backtrace logging with correlation fields
- Added microsecond-precision timing to configuration freeze process
- Added unique error ID generation for nested error handler failures (links via ``original_error_id``)

Changed
-------

- Timing precision standardization: All timing calculations now use microsecond precision instead of milliseconds. This affects authentication duration tracking and request lifecycle timing. Duration values are now reported in microseconds as integers (e.g., ``15200`` instead of ``15.2``).
- Request completion hooks API improvement: ``Otto.on_request_complete`` callbacks now receive a ``Rack::Response`` object instead of the raw ``[status, headers, body]`` tuple. This provides a more developer-friendly API consistent with ``Rack::Request``, allowing clean access via ``res.status``, ``res.headers``, and ``res.body`` instead of array indexing.
- All timing now uses microseconds (``Otto::Utils.now_in_μs``) for consistency
- Configuration freeze process now logs detailed timing metrics

Documentation
-------------

- Added example application demonstrating three new logging patterns (``examples/logging_improvements.rb``)
- Documented base context pattern for downstream projects to inject custom correlation fields
- Added output examples for both structured and standard loggers

AI Assistance
-------------

- This enhancement was developed with assistance from Claude Code (Opus 4.1)

   .. _changelog-2.0.0.pre4:


2.0.0.pre4 — 2025-10-20
=======================
Changed
-------
- Authentication moved from middleware to RouteAuthWrapper at handler level (executes after routing)
- RouteAuthWrapper now wraps all routes and provides session persistence, security headers, strategy caching, and pattern matching (exact, prefix, fallback)
- env['otto.strategy_result'] now guaranteed present on all routes (authenticated or anonymous)
- Renamed MiddlewareStack#build_app to #wrap (reflects per-request wrapping vs one-time initialization)

Removed
-------
- AuthenticationMiddleware (executed before routing)
- enable_authentication! (RouteAuthWrapper handles auth automatically)
- Defensive nil fallback from LogicClassHandler (no longer needed)

Fixed
-----
- Session persistence: env['rack.session'] now references same object as strategy_result.session
- Security headers included on all auth failure responses (401/302)
- Anonymous routes now receive StrategyResult with IP metadata

Documentation
-------------
- Updated CLAUDE.md with RouteAuthWrapper architecture
- Updated env_keys.rb to document strategy_result guarantee
- Added tests for anonymous route handling


.. _changelog-2.0.0.pre2:

2.0.0.pre2 — 2025-10-11
=======================

Added
-----

- Added `StrategyResult` class with improved user model compatibility and cleaner API
- Helper methods ``authenticated?``, ``has_role?``, ``has_permission?``, ``user_name``, ``session_id`` for cleaner Logic class implementation
- Added JSON request body parsing support in Logic class handlers
- Added new modular directory structure under ``lib/otto/security/``
- Added backward compatibility aliases to maintain existing API compatibility
- Added proper namespacing for authentication components and middleware classes

Changed
-------

- **BREAKING**: Logic class constructor signature changed from ``initialize(session, user, params, locale)`` to ``initialize(context, params, locale)``
- Logic classes now receive an immutable context object instead of separate session/user parameters
- LogicClassHandler simplified to single arity pattern, removing backward compatibility code
- Authentication middleware now creates `StrategyResult` instances for all requests
- Replaced `RequestContext` with `StrategyResult` class for better authentication handling
- Simplified authentication strategy API to return `StrategyResult` or `nil` for success/failure
- Enhanced route handlers to support JSON request body parsing
- Updated authentication middleware to use `StrategyResult` throughout
- Reorganized Otto security module structure for better maintainability and separation of concerns
- Moved authentication strategies to ``Otto::Security::Authentication::Strategies`` namespace
- Moved security middleware to ``Otto::Security::Middleware`` namespace
- Moved ``StrategyResult`` and ``FailureResult`` to ``Otto::Security::Authentication`` namespace

Removed
-------

- Removed `RequestContext` class (which was introduced and then replaced by `StrategyResult` during this development cycle)
- Removed `AuthResult` class from authentication system
- Removed `ConcurrentCacheStore` example class for an ActiveSupport::Cache::MemoryStore-compatible interface with Rack::Attack
- Removed OpenStruct dependency across the framework

Documentation
-------------

- Updated migration guide with comprehensive examples for the new context object and step-by-step conversion instructions
- Updated Logic class examples in advanced_routes and authentication_strategies to demonstrate new pattern
- Enhanced documentation with API reference and helper method examples for the new context object

AI Assistance
-------------

- AI-assisted architectural design for RequestContext Data class and security module reorganization
- Comprehensive migration of Logic classes and documentation with AI guidance for consistency
- Automated test validation and intelligent file organization following Ruby conventions


.. _changelog-2.0.0-pre1:

2.0.0-pre1 — 2025-09-10
=======================

Added
-----

- Comprehensive test coverage for error handling methods (handle_error, secure_error_response,
json_error_response)
- Test coverage for private configuration methods (configure_locale, configure_security,
configure_authentication, configure_mcp)
- Expanded MCP functionality test coverage including route parsing and server initialization
- Security header validation in all error responses
- Content negotiation testing for JSON vs plain text error responses
- Development vs production mode error handling verification

- ``Otto::Security::Configurator`` class for consolidated security configuration
- ``Otto::Core::MiddlewareStack`` class for enhanced middleware management
- Unified ``security.configure()`` method for streamlined security setup
- Middleware introspection capabilities via ``middleware_list`` and ``middleware_details`` methods

Changed
-------

- **BREAKING**: Direct middleware_stack manipulation no longer supported. Use ``otto.use()`` instead
of ``otto.middleware_stack <<``. See `migration guide <docs/migrating/v2.0.0-pre1.md>`__ for upgrade
path.

- Refactored main Otto class from 767 lines to 348 lines using composition pattern (#29)
- Modernized initialization method with helper functions while maintaining backward compatibility
- Applied Ruby 3.2+ features including pattern matching and anonymous block forwarding
- Improved method organization and separation of concerns

- Refactored security configuration methods to use new ``Otto::Security::Configurator`` facade
- Enhanced middleware stack management with better registration and execution interfaces
- Improved separation of concerns between security configuration and middleware handling

- Unified middleware stack implementation for improved performance and consistency
- Optimized middleware lookup and registration with O(1) Set-based tracking
- Memoized middleware list to reduce array creation overhead
- Improved middleware registration to handle varied argument scenarios

Documentation
-------------

- Added changelog management system with Scriv configuration
- Created comprehensive changelog process documentation

AI Assistance
-------------

- Comprehensive test suite development covering 76 new test cases across 3 test files
- Error handling analysis and edge case identification
- Configuration method testing strategy development
- MCP functionality testing with proper mocking and stubbing techniques
- Test quality assurance ensuring all 460 examples pass with 0 failures

- Extracted core Otto class functionality into 5 focused modules (Router, FileSafety, Configuration,
ErrorHandler, UriGenerator) using composition pattern for improved maintainability while preserving
complete API backward compatibility (#28)

- Comprehensive refactoring implementation developed with AI assistance
- Systematic approach to maintaining backward compatibility during modernization
- Full test suite validation ensuring zero breaking changes across 460 test cases

- Comprehensive refactoring of middleware stack management
- Performance optimization and code quality improvements
- Developed detailed migration guide for smooth transition
