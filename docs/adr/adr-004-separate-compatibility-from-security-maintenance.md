# ADR-004: Separate compatibility support from security maintenance

- **Status:** Accepted
- **Date:** 2026-09-04

## Context

Otto declares Ruby and dependency version ranges so that applications can resolve
a compatible bundle. Those declarations can be mistaken for security guarantees:
a Ruby version may remain compatible with Otto after upstream security maintenance
ends, and a gem version may satisfy Otto's dependency range after a new advisory
makes that version unsafe.

Otto's own lockfile and CI matrix test Otto's development resolution and API
compatibility. They cannot determine or secure the final dependency graph resolved
by every application that installs Otto. The current Ruby support matrix,
dependency constraints, and audit procedures also change over time, so they belong
in maintained reference documentation rather than in a historical decision record.

## Decision

Otto treats compatibility support as distinct from upstream security maintenance.
Compatibility testing means that Otto is expected to work on a runtime or with a
dependency version; it does not mean that the runtime or dependency still receives
security fixes.

The version ranges in `otto.gemspec` express API compatibility. Their lower bounds
are not guaranteed security floors, and installation success does not certify a
resolved bundle as free of known vulnerabilities.

Applications that consume Otto own the security auditing and maintenance of their
resolved lockfiles. Otto may constrain a known-bad version when warranted, but
maintainer constraints and CI do not replace application-level auditing.

Otto continues to test Ruby 3.2 as a compatibility target despite its upstream end
of life. This preserves compatibility for users who still need that runtime without
representing Ruby 3.2 as security-maintained.

## Consequences

- Otto can retain useful compatibility coverage without implying that it provides
  upstream interpreter or dependency security maintenance.
- Applications with security-maintenance requirements must select an upstream-
  maintained Ruby, audit their complete resolved bundles, and deploy audited
  lockfiles.
- Dependency lower bounds remain stable compatibility baselines unless an API or
  security issue requires a targeted constraint change.
- Ruby 3.2 compatibility failures remain release-relevant while it is a blocking
  target, even though applications should not infer that Ruby 3.2 receives security
  fixes.
- The current support matrix, compatibility ranges, audit commands, and consumer
  procedures may change in the canonical reference without rewriting this ADR. A
  later architectural decision may supersede this record if the policy changes.

## Related documentation

- [Runtime and dependency security policy](../reference/runtime-and-dependency-security.md)
  — canonical current matrix, compatibility policy, and consumer audit procedures
