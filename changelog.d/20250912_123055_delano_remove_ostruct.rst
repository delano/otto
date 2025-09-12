Changed
-------

- Replaced `RequestContext` with `StrategyResult` class for better authentication handling
- Simplified authentication strategy API to return `StrategyResult` or `nil` for success/failure
- Enhanced route handlers to support JSON request body parsing
- Updated authentication middleware to use `StrategyResult` throughout

Added
-----

- Added `StrategyResult` class with improved user model compatibility and cleaner API
- Added JSON request body parsing support in Logic class handlers

Removed
-------

- Removed `RequestContext` class (replaced by `StrategyResult`)
- Removed `AuthResult` class from authentication system
- Removed OpenStruct dependency across the framework
