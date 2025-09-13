CHANGELOG.rst
=============

All notable changes to Otto are documented here.

The format is based on `Keep a
Changelog <https://keepachangelog.com/en/1.1.0/>`__, and this project
adheres to `Semantic
Versioning <https://semver.org/spec/v2.0.0.html>`__.

.. raw:: html

   <!--scriv-insert-here-->

.. _changelog-2.0.0-pre1:

2.0.0-pre1 — 2025-09-10
=======================

Added
-----

- Comprehensive test coverage for error handling methods (handle_error, secure_error_response, json_error_response)
- Test coverage for private configuration methods (configure_locale, configure_security, configure_authentication, configure_mcp)
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

- **BREAKING**: Direct middleware_stack manipulation no longer supported. Use ``otto.use()`` instead of ``otto.middleware_stack <<``. See `migration guide <docs/migrating/v2.0.0-pre1.md>`__ for upgrade path.

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

- Extracted core Otto class functionality into 5 focused modules (Router, FileSafety, Configuration, ErrorHandler, UriGenerator) using composition pattern for improved maintainability while preserving complete API backward compatibility (#28)

- Comprehensive refactoring implementation developed with AI assistance
- Systematic approach to maintaining backward compatibility during modernization
- Full test suite validation ensuring zero breaking changes across 460 test cases

- Comprehensive refactoring of middleware stack management
- Performance optimization and code quality improvements
- Developed detailed migration guide for smooth transition
