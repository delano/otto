# GitHub Actions

## Every `uses:` is pinned to a commit SHA

All third-party actions in `.github/workflows/` are pinned to a full 40-character
commit SHA with a trailing version comment:

```yaml
uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

Tags and branches are mutable — an upstream force-push silently changes what runs
with our secrets. The SHA is the security boundary; the comment is only for humans.
Do not merge a workflow that references `@v4`, `@main`, or `@beta`.

Keep one version per action across the repo so the pins converge.

## Resolving a tag to a SHA

```sh
gh api repos/actions/checkout/commits/v7.0.1 --jq .sha
```

This dereferences annotated tags for you. To see what tags exist:
`gh api repos/OWNER/REPO/releases --jq '.[].tag_name' | head`.

## Updating pins

Dependabot (`.github/dependabot.yml`) checks weekly and rewrites both the SHA and
the version comment. The `github-actions` group means all bumps arrive in a single
PR rather than one per action. Review the upstream changelog before merging;
a SHA bump is arbitrary code execution in CI.

## claude-code-action

Pinned to `v1.0.216`. `@beta` is a branch, not a release, so it is not permitted
here. The v1 line dropped several v0 inputs — `model`, `fallback_model`,
`direct_prompt` — which now go through `claude_args` (CLI flags) and `prompt`.
When bumping, diff the new tag's `action.yml` `inputs:` against the `with:` keys
in `claude.yml` and `claude-code-review.yml`; undeclared inputs are ignored
silently rather than failing the run.
