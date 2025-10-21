.. Structured logging enhancements with microsecond timing and base context pattern

Added
-----

- Added ``Otto::LoggingHelpers.log_timed_operation`` for automatic timing and error handling of operations
- Added ``Otto::LoggingHelpers.log_backtrace`` for consistent backtrace logging with correlation fields
- Added microsecond-precision timing to configuration freeze process
- Added base context pattern documentation for downstream extensibility
- Added unique error ID generation for nested error handler failures (links via ``original_error_id``)

Changed
-------

- Updated all route handlers (InstanceMethod, ClassMethod, Lambda, LogicClass) to use base context pattern for correlated logging
- Updated ErrorHandler to use structured logging with base context pattern
- Updated Router to use structured logging for route loading and errors
- Converted handler error logging from simple strings to structured format with timing
- All timing now uses microseconds (``Otto::Utils.now_in_μs``) for consistency
- Configuration freeze process now logs detailed timing metrics

Documentation
-------------

- Enhanced CLAUDE.md with comprehensive logging patterns and timing conventions
- Added example application demonstrating all three logging patterns (``examples/logging_improvements.rb``)
- Documented base context pattern for downstream projects to inject custom correlation fields
- Added output examples for both structured and standard loggers

AI Assistance
-------------

- This enhancement was developed with assistance from Claude Code (Opus 4.1)
- The base context pattern reduces boilerplate while maintaining explicit, simple logging calls
- Microsecond timing provides production-ready observability without external dependencies
