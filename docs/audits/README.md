# Code audits

Point-in-time audits of the Otto codebase. Each report names the commit it
examined. Line numbers, quoted code and reproduction results refer to that
commit, not to the current tree. A report can open with a status section
rechecked against a later commit; that section names its own commit.

## Status of these documents

The reports are agent output. AGENTS.md says: "Delivery notes, commit messages,
issue discussions, summaries, and agent-authored text are non-authoritative
unless an authoritative source incorporates them explicitly." Treat each finding
as a lead for maintainers. A finding states project behavior or policy only once
a guide, reference page, ADR or merged change adopts it.

Severity ratings are the auditors' judgment. Finding IDs (S1, C2, D1 and so on)
are local to one report.

## Reports

| Date | Commit | Dimensions | Report |
| --- | --- | --- | --- |
| 2026-09-28 | `359a25f` (v2.12.0) | Security, correctness, test coverage, dead code, dependency risk | [v2.12.0 code audit](2026-09-28-v2.12.0-code-audit.md) |

## Follow-up: 2026-09-28 audit

Each critical and high finding has its own pull request. The fix in each PR was
reproduced with a failing spec before it was written; the PR description holds
that evidence. States were last checked on 2026-10-12, with main at `d78b9b4`.

| Finding | Severity | Pull request | State |
| --- | --- | --- | --- |
| S1, C1: client IP resolved from the leftmost X-Forwarded-For entry | Critical | [#292](https://github.com/delano/otto/pull/292) | Merged 2026-10-06 |
| S2: `Config#deep_freeze!` not idempotent with MCP middleware | High | [#293](https://github.com/delano/otto/pull/293) | Merged 2026-10-06 |
| C2: HEAD dispatch mutates the route tables | High | [#294](https://github.com/delano/otto/pull/294) | Merged 2026-10-06 |
| C3: generated CSRF secret warning writes to the frozen config | High | [#297](https://github.com/delano/otto/pull/297) | Merged 2026-10-06 |
| C4: auth success replaces `rack.session` with `{}` | High | [#298](https://github.com/delano/otto/pull/298) | Merged 2026-10-06 |
| C5: CSRF session binding changes between GET and POST | High | [#295](https://github.com/delano/otto/pull/295) | Merged 2026-10-06 |
| C6, T1: `csrf_secret=` accepts `''` and `nil` | High | [#299](https://github.com/delano/otto/pull/299) | Merged 2026-10-06 |
| D1: `auth=` and `role=` on MCP and TOOL routes not enforced | High | [#296](https://github.com/delano/otto/pull/296) | Merged 2026-10-06 |

These related pull requests are not findings from the report:

| Change | Origin | Pull request | State |
| --- | --- | --- | --- |
| Redact secrets from `#inspect` | The CSRF secret showed in `Security::Config#inspect` and `FrozenError` messages; found while preparing #297 | [#300](https://github.com/delano/otto/pull/300) | Merged 2026-10-06 |
| Bind the CSRF fallback cookie to a `__Host-` name on HTTPS | Changes the cookie fallback in the same CSRF binding lookup that #295 changes | [#302](https://github.com/delano/otto/pull/302) | Merged 2026-10-12 |
| Resolve the CSRF binding without minting on failures or copying store ids | Left after #302: a failed CSRF check created a binding, and HTML responses copied the session store's id into the binding cookie | [#308](https://github.com/delano/otto/pull/308) | Open |
| Keep CSRF responses out of shared caches and set the binding cookie once | Left after #302: no `Cache-Control` on responses that set the binding cookie, and a duplicate `Set-Cookie` when the middleware runs twice; also fixes C8 | [#309](https://github.com/delano/otto/pull/309) | Open |

Three medium and low findings have a pull request:

| Finding | Severity | Pull request | State |
| --- | --- | --- | --- |
| S3, C11: a non-String `_csrf_token` parameter returns 500 instead of 403 | Low | [#307](https://github.com/delano/otto/pull/307) | Open |
| C8: CSRF token injection replaces the response body without closing the original | Medium | [#309](https://github.com/delano/otto/pull/309) | Open |

The other medium and low findings have no pull request yet. All 23 are still
present at `4e2758c`; the report's
[status section](2026-09-28-v2.12.0-code-audit.md#status-on-main) gives each
one's location on main and a second raise site for C9.

When one of these pull requests merges or closes, update its State cell.
