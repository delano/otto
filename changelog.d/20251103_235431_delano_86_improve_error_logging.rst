Added
-----

- Error handler registration system for expected business logic errors. Register handlers with ``otto.register_error_handler(ErrorClass, status: 404, log_level: :info)`` to return proper HTTP status codes and avoid logging expected errors as 500s with backtraces. Supports custom response handlers via blocks for complete control over error responses.

Changed
-------

- Backtrace logging now always logs at ERROR level (was DEBUG) with sanitized file paths for security. Backtraces for unhandled 500 errors are always logged regardless of ``OTTO_DEBUG`` setting, with paths sanitized to prevent exposing system information (project files show relative paths, gems show ``[GEM] name-version/path``, Ruby stdlib shows ``[RUBY] filename``).
- Increased backtrace limit from 10 to 20 lines for critical errors to provide better debugging context.

AI Assistance
-------------

- Implemented error handler registration architecture with comprehensive test coverage (17 test cases) using sequential thinking to work through security implications and design decisions. AI assisted with path sanitization strategy, error classification patterns, and ensuring backward compatibility with existing error handling.
