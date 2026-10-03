# Contributing

Issues and pull requests are welcome. This is a small repo with a small
surface: one composite action (`action.yml`) wrapping one bash script
(`build.sh`).

Found a security problem? Do not open an issue - see [SECURITY.md](SECURITY.md).

## Opening an issue

For a packaging bug, the details worth having are:

- the `uses:` step, with `python-version` and `platform`
- the `::error::` or `error:` line the run printed
- the log of the failing step, or which `[N/5]` group it died in
- whether it also fails when you run `build.sh` directly (see below)

A link to a public run beats a description of one.

## Running the tests

`shellcheck` and `bats` are the only tools the unit tests need:

```bash
# macOS
brew install shellcheck bats-core

# Ubuntu
sudo apt-get install --no-install-recommends shellcheck bats
```

```bash
shellcheck build.sh
bats tests/build.bats
```

Both run on every pull request through `.github/workflows/ci.yml`. They take
seconds and need no network.

`tests/build.bats` covers the pure helpers at the top of `build.sh` and nothing
else. It sources the script, which defines its functions without running the
pipeline - that is what the `BASH_SOURCE`/`$0` guard at the bottom of the file
is for. Keep new helpers pure and they stay testable the same way.

## Running the action locally

`build.sh` runs outside Actions. It needs `uv`, `uvx` and `jq` on PATH, and it
falls back to `shasum` where there is no `sha256sum`, so a macOS machine works:

```bash
./build.sh \
  --input tests/fixtures/single \
  --output dist \
  --python 3.13 \
  --platform aarch64-manylinux2014
```

Two differences from a CI run. The Linux guard is skipped, because it keys off
`RUNNER_OS` and only Actions sets that. And no step outputs are written,
because `GITHUB_OUTPUT` is unset - the paths and sizes are printed instead.

It builds in `<input>/build` and removes that directory before and after the
run. Removed, not emptied: never point `--build-dir` at anything you want to
keep.

## The end-to-end suite

`.github/workflows/e2e.yml` runs the action against the fixtures in `tests/`:
four Python versions across both platforms, plus the multi-lambda pattern, hash
stability, the guard rails, and artifact naming. It is the only suite that
proves the action works, and it costs a lot more than `ci.yml`.

Workflows on a pull request from a fork wait for a maintainer to approve the
run. That is GitHub's setting for outside contributors, not something your PR
did wrong.

The fixtures pin `orjson` at an exact version on purpose: the matrix asserts
the exact filename of the compiled extension module it ships
(`orjson.cpython-313-aarch64-linux-gnu.so` and friends). Without a compiled
dependency, both platforms would resolve the same `py3-none-any` wheels and the
matrix would prove nothing. Bumping that pin means updating the assertion with
it, so it is a hand edit rather than a Dependabot PR.

## Adding a Python runtime

AWS has no API for the supported runtime set, so the list is kept by hand and
lives in more than one place. All of these need the edit:

- `SUPPORTED_PYTHON_VERSIONS` in `build.sh`
- the `python-version` description in `action.yml`
- the inputs table and the "Supported runtimes" section in `README.md`
- the `python-version` matrix in `.github/workflows/e2e.yml`
- `tests/build.bats`, where the rejected-version cases name the versions either
  side of the supported set

A newly deprecated runtime also needs a date in
`python_version_deprecation_date`, which is what turns its build-time
`::warning::` on. Those dates are hand-written too, from AWS docs.

## House rules

- Pin every action to a full commit SHA with a trailing `# vX.Y.Z` comment.
  Dependabot rewrites the SHA and the comment together, so the form matters.
- `.editorconfig` covers indentation and line endings.

## Known gaps

Already known, so there is no need to file them - a PR is welcome:

- `--build-dir` exists in `build.sh` but the action does not expose it, so a
  project with its own `build/` directory has no way to opt out.
- The nested-zip fallback is only tested on the side where it does not trigger.
  Proving the other side needs a fixture over 250 MiB.
- Only the `manylinux2014` targets are mapped. `manylinux_2_28` is a real uv
  target, it just has no Lambda architecture mapping here yet.
