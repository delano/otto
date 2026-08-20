# Otto documentation

Otto is a Rack router whose application model starts with a plain-text route
file and Ruby handlers. It also provides opt-in security controls,
privacy-preserving request handling, authentication hooks, and small
integrations for network services.

This page is the documentation map. It is intentionally a map, not an
exhaustive API reference: public classes, method signatures, and implementation
details remain in the code and its generated API documentation. Guides should
explain when to use a capability, its security and operational constraints, and
the smallest complete configuration that uses it safely.

## Capabilities at a glance

| Area | What Otto provides | Planned reader-facing guide |
| --- | --- | --- |
| Application model | Plain-text routes; class, instance, Logic-class, and registered lambda handlers; response selection | `guides/routing.md` |
| Request lifecycle | Rack integration, middleware ordering, helper registration, lifecycle hooks, and boot-time configuration | `guides/application-lifecycle.md` |
| Authentication and authorization | Named authentication strategies, ordered multi-strategy fallback, terminal failures, route roles, and resource-level authorization | `guides/authentication.md` |
| Security | CSRF enforcement, request validation, rate limiting, security headers, CSP, error handling, and trusted proxies | `guides/security.md` |
| Privacy and network identity | IP privacy profiles, privacy-safe client signals, country resolution, ASN lookup, and anonymizer classification | `guides/privacy.md` |
| Internationalization | Locale configuration and request locale resolution | `guides/locales.md` |
| Operations | Structured logging, safe error reporting, static files, and testing Otto applications | `guides/operations.md` |
| Integrations | Model Context Protocol (MCP) endpoints and Caddy on-demand TLS permission checks | `integrations/mcp.md`, `integrations/caddy-tls.md` |

The target names above are the next public documentation surface. They are not
links yet: a link should only be added when the guide is accurate, reviewed, and
shipped.

## Start here today

- [Project README](../README.md) — installation and a minimal Rack app.
- [Geo-country resolution](geo-country.md) — trusted headers, local MMDB
  fallback, and the privacy model.
- [ASN and anonymizer enrichment](enrichment.md) — opt-in network signals and
  their database contracts.
- [Migration guides](migrating/) — version-specific behavior changes.
- [Changelog](../CHANGELOG.rst) — release history and upgrade-impacting changes.

The following tracked documents are useful historical or design context. They
are **not** the primary entry point for implementing an application:

- [Multi-strategy authentication design](multi-strategy-authentication-design.md)
- [Authentication/authorization landscape](modern-authentication-authorization-landscape.md)
- [Reverse-proxy/network-service design](reverse-proxy-network-services.md)
- [Streaming analysis](1108-STREAMING_ARCHITECTURE_ANALYSIS.md) and
  [summary](1108-STREAMING_SUPPORT_SUMMARY.md)
- [Ruby `IPAddr#to_s` encoding note](ipaddr-encoding-quirk.md)

## Target structure

The documentation should grow by reader task and stability, not by the order in
which implementation work occurred:

```text
docs/
├── README.md                         # this map and current entry point
├── getting-started.md                # first app after the README example
├── guides/                           # stable, task-oriented application guides
│   ├── routing.md
│   ├── application-lifecycle.md
│   ├── authentication.md
│   ├── security.md
│   ├── privacy.md
│   ├── locales.md
│   └── operations.md
├── integrations/                     # deployment-specific contracts
│   ├── mcp.md
│   └── caddy-tls.md
├── reference/                        # compact, stable contracts—not a code mirror
│   ├── route-syntax.md
│   ├── configuration.md
│   ├── request-and-response.md
│   └── errors.md
├── migrating/                        # release-specific upgrade guides
└── maintainers/                      # architecture, decisions, and investigations
    ├── decisions/
    └── investigations/
```

### What belongs where

- **Getting started** gets a reader from an installed gem to a running app and
  links to the next common task.
- **Guides** answer a single application task. They include safe defaults,
  prerequisites, a compact example, verification, and links to the relevant
  compact reference.
- **Integrations** document an external system's HTTP or deployment contract,
  including trust boundaries and failure behavior.
- **Reference** records only contracts that must be precise across multiple
  guides: route grammar, configuration names, request/response helpers, error
  behavior, and environment keys. It links to code rather than repeating every
  method.
- **Migration** documents a release-bound action and its before/after behavior.
  It does not become a general guide.
- **Maintainer material** preserves rationale, alternatives, and unfinished
  exploration without asking application developers to infer current behavior
  from a proposal.

## Migration plan for the current directory

This is a classification plan, not a request to rewrite every document now.
Move or replace a document only when its destination guide is ready. Some
working-tree documents are currently ignored by `docs/.gitignore`; reconcile
and explicitly track them before treating them as published documentation.

| Current material | Target disposition | Reason |
| --- | --- | --- |
| `geo-country.md`, `enrichment.md` | Fold into `guides/privacy.md`; retain focused pages while they remain useful | They are current, task-oriented, and contain important privacy constraints. |
| `authentication.md`, `AUTH_STRATEGIES.txt` | Replace with `guides/authentication.md` and `reference/route-syntax.md` | The guide should reflect current strategy results, role rules, ordered fallback, and terminal failures in one maintained place. |
| `ADVANCED_ROUTES.txt` | Replace with `guides/routing.md` and `reference/route-syntax.md` | Route grammar and target kinds are a public contract; the current quick reference is incomplete for modern handler types and security-gating validation. |
| `ip_privacy.md`, `structured_logging.md`, `configuration_freezing.md` | Reconcile against current behavior, then fold into privacy, operations, and lifecycle guides | They describe durable concepts, but must be verified before being promoted as canonical documentation. |
| `reverse-proxy-network-services.md` | Extract `integrations/caddy-tls.md`; retain the design record under `maintainers/decisions/` | Operators need a concise deployment guide; implementation rationale should remain separately discoverable. |
| `MCP_IMPLEMENTATION.md` | Extract `integrations/mcp.md`; retain implementation notes under `maintainers/` | The protocol user and the maintainer have different questions. |
| `multi-strategy-authentication-design.md`, `route-auth-wrapper-resolution.md`, landscape papers | Move to `maintainers/decisions/` or `maintainers/investigations/`; add an outcome/status note | These explain why and how work was done, rather than providing the current application contract. |
| Dated architecture, hardening, enhancement, and streaming files | Move to `maintainers/investigations/`; keep only active proposals in the main tree | Dates and working notes are valuable history but should not compete with supported guides. |
| `testing-guide.md` | Reconcile with current test support, then publish as `guides/operations.md` or `guides/testing.md` | Testing is an application task, not an implementation design. |

## Documentation rules for future changes

1. Add a capability to this map only when a stable guide exists, or when the
   README provides the complete safe first-use example.
2. Update the affected guide and its compact reference in the same change as a
   public behavior change. Use the changelog for the release record, not as a
   substitute for instructions.
3. Record security defaults, trust boundaries, configuration-freezing timing,
   and failure behavior where they affect use. Those are part of the contract.
4. Keep a proposal separate from its outcome. When work lands, add a short
   status/outcome note and link from the guide to the decision only when the
   rationale helps a maintainer.
5. Prefer one canonical page for each task. Other pages should link to it rather
   than copy examples or option lists.
6. Validate every new command and example against the supported Ruby and Rack
   versions before publishing it as runnable documentation.

## First documentation milestone

A useful first milestone is intentionally small:

1. Publish this map and make it the `README` documentation destination.
2. Write `reference/route-syntax.md` from `Otto::RouteDefinition` and route
   handler behavior, including handler kinds and fail-fast `auth=`, `role=`, and
   `csrf=` option syntax.
3. Publish `guides/authentication.md`, `guides/privacy.md`, and
   `integrations/caddy-tls.md` by reconciling the existing material with the
   current code and specs.
4. Move completed designs and working investigations behind `maintainers/` so
   the top-level reader journey remains stable.

That sequence makes Otto's current shape visible quickly while leaving room for
new capabilities without turning `docs/` into a second, drifting codebase.
