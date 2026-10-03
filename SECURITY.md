# Security policy

This action runs inside other people's build jobs and writes the artifact they
deploy, so a problem here reaches further than this repository. Reports are
welcome.

## Reporting a vulnerability

Please do not open a public issue.

Two private channels, either is fine:

- GitHub's private vulnerability reporting: the **Security** tab of this
  repository, then **Report a vulnerability**. The report stays private until
  there is a fix to publish.
- Email <me@dhrimov.dev>.

Worth including: what an attacker gets out of it, the version or commit SHA you
looked at, and the smallest workflow that shows the problem.

This is a personal project, not a funded one. Reports are read and answered on
a best-effort basis, and there is no bounty.

## Supported versions

The latest `v1.x.y` release. A fix ships as a new release rather than as a
patch to an older tag, because published release tags are immutable here and
cannot be moved.

## Scope

In scope: `action.yml` and `build.sh` - argument handling, the guard rails,
shell quoting, report parsing, and what ends up in the zip.

Out of scope here, but worth reporting upstream:

- [`package-python-function`](https://github.com/BrandonLWhite/package-python-function),
  which builds the zip
- [`uv`](https://github.com/astral-sh/uv) and
  [`setup-uv`](https://github.com/astral-sh/setup-uv)
- [`actions/upload-artifact`](https://github.com/actions/upload-artifact)

A caller's own workflow is out of scope too. Untrusted input reaching this
action's inputs is a problem in the workflow that passes it along.

## Pinning

Pin the action to a full commit SHA rather than to a tag:

```yaml
- uses: dhrimov/package-python-lambda-gha@<40-char-sha> # v1.0.0
```

A tag is a movable pointer, and moving one is how `tj-actions/changed-files`
was turned against its callers in March 2025. This repository has GitHub's
immutable releases turned on, so a published `vX.Y.Z` tag cannot be moved or
deleted - but `v1` is a floating alias by design, and it does move.
