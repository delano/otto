Changed
-------

- Reorganized Otto security module structure for better maintainability and separation of concerns
- Moved authentication strategies to ``Otto::Security::Authentication::Strategies`` namespace
- Moved security middleware to ``Otto::Security::Middleware`` namespace
- Moved ``StrategyResult`` and ``FailureResult`` to ``Otto::Security::Authentication`` namespace

Added
-----

- Added new modular directory structure under ``lib/otto/security/``
- Added backward compatibility aliases to maintain existing API compatibility
- Added proper namespacing for authentication components and middleware classes

AI Assistance
-------------

- Comprehensive security module reorganization with systematic namespace restructuring
- Automated test validation to ensure backward compatibility during refactoring
- Intelligent file organization following Ruby conventions and single responsibility principles
