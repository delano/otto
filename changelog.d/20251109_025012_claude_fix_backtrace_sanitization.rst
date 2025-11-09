.. Changed in: otto
.. Fixes issue:

Improved backtrace sanitization security and readability
---------------------------------------------------------

**Security Enhancements:**

- Fixed bundler gem path detection to correctly sanitize git-based gems
- Now properly handles nested gem paths like ``/gems/3.4.0/bundler/gems/otto-abc123/``
- Strips git hash suffixes from bundler gems (``otto-abc123def456`` → ``otto``)
- Removes version numbers from regular gems (``rack-3.2.4`` → ``rack``)
- Prevents exposure of absolute paths, usernames, and project names in logs

**Improvements:**

- Bundler gems now show as ``[GEM] otto/lib/otto/route.rb:142`` instead of ``[GEM] 3.4.0/bundler/gems/...``
- Regular gems show cleaner output: ``[GEM] rack/lib/rack.rb:20`` instead of ``[GEM] rack-3.2.4/lib/rack.rb:20``
- Multi-hyphenated gem names handled correctly (``active-record-import-1.5.0`` → ``active-record-import``)
- Better handling of version-only directory names in gem paths

**Documentation:**

- Added comprehensive backtrace sanitization section to CLAUDE.md
- Documented security guarantees and sanitization rules
- Added examples showing before/after path transformations
- Created comprehensive test suite for backtrace sanitization

**Rationale:**

Raw backtraces expose sensitive information:
- Usernames (``/Users/alice/``, ``/home/admin/``)
- Project structure and internal organization
- Gem installation paths and Ruby versions
- System architecture details

This improvement ensures all backtraces are sanitized automatically, preventing accidental leakage of sensitive system information while maintaining readability for debugging.
