# Package Python Lambda

A composite GitHub Action that packages a Python AWS Lambda project (built with
[`uv`](https://github.com/astral-sh/uv)) into a reproducible deployment zip and
leaves it on the runner's filesystem for your next step to pick up.

It installs and caches `uv` for you, checks the requested runtime and target
platform before doing any real work, and reports the zip's path, hash and sizes
as step outputs.

Packaging is Linux-only. Deploying the zip - Terraform, the AWS CLI, anything
else - is out of scope. This action's contract ends at producing the zip.

## Usage

### A single-lambda repo

```yaml
jobs:
  package:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v7

      - id: package
        uses: dhrimov/package-python-lambda-gha@v1
        with:
          input-path: .
          output-path: terraform
          python-version: "3.13"
          platform: aarch64-manylinux2014

      # The zip is on the filesystem already - no artifact round-trip needed.
      - run: terraform apply -var "lambda_zip=${{ steps.package.outputs.zip-path }}"
        working-directory: terraform
```

### A monorepo with several lambdas

The action packages one lambda per call. Looping is your job, through your own
matrix - which is also what gets each lambda built in parallel:

```yaml
jobs:
  package:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    strategy:
      fail-fast: false
      matrix:
        lambda: [orders, payments]
    steps:
      - uses: actions/checkout@v7

      - uses: dhrimov/package-python-lambda-gha@v1
        with:
          input-path: services/${{ matrix.lambda }}
          output-path: dist
          python-version: "3.13"
          platform: aarch64-manylinux2014
          upload-artifact: "true"
```

### Pinning

The safer form pins the action to a full commit SHA and keeps the version in a
trailing comment. That comment is what Dependabot and Renovate read when they
bump it:

```yaml
- uses: dhrimov/package-python-lambda-gha@<40-char-sha> # v1.0.0
```

A floating `@v1` also exists and always points at the latest `v1.x.y`. It is
easier to read, but a tag can be moved to another commit later, and some
organizations run a policy that fails workflows using unpinned actions.

### Permissions

The action makes no authenticated GitHub API calls of its own and needs no
`GITHUB_TOKEN` scopes. The `contents: read` in the examples above is for your
own `actions/checkout` step. `upload-artifact: true` needs nothing extra.

## Inputs

| Input | Default | Description |
|---|---|---|
| `input-path` | `.` | Directory containing the Lambda project's `pyproject.toml`. |
| `output-path` | `terraform` | Directory the zip is written to. Created if missing. |
| `python-version` | **none - required** | Target AWS Lambda Python runtime: `3.11`, `3.12`, `3.13`, or `3.14`. |
| `platform` | **none - required** | uv target platform: `aarch64-manylinux2014` or `x86_64-manylinux2014`. |
| `packager-version` | `1.0.0` | `package-python-function` version to package with. |
| `uv-version` | `""` | uv version to install. Empty means the version pinned in your project, or the latest release. |
| `enable-cache` | `true` | Turn on uv's Actions cache, keyed off `<input-path>/uv.lock`. |
| `fail-on-non-linux` | `true` | Refuse to run on a non-Linux runner. |
| `upload-artifact` | `false` | Upload the zip as a workflow artifact. |
| `artifact-name` | derived | Artifact name. See [Artifacts](#artifacts). |
| `artifact-retention-days` | `7` | Days to keep the uploaded artifact. |

### The build directory is `<input-path>/build`, and it gets deleted

> [!WARNING]
> The action builds in `<input-path>/build` and **deletes that whole
> directory** before and after every build. Anything you keep there is lost.

`build.sh` takes a `--build-dir` flag to move it, but the action does not
expose it yet. There is no input for it, so the path is always
`<input-path>/build`. If your project already uses a `build/` directory, move
that content somewhere else before using this action.

### `python-version` and `platform` have no defaults on purpose

These two are the whole point of the action. A default would quietly pick the
architecture and ABI that every compiled dependency in your package is built
against. Get it wrong against the Lambda function's real `architecture` and
`runtime`, and the package still deploys without a word - it only breaks once
the function runs. Naming both every time is what stops that.

GitHub does not enforce `required: true` on composite action inputs, so the
action checks them itself and fails with an `::error::` before installing
anything.

The `platform` you pass here has to match the `architecture` set on the Lambda
resource itself (`arm64` for `aarch64-manylinux2014`, `x86_64` for
`x86_64-manylinux2014`). The action never sees that resource, so keeping the
two in alignment is your job.

### Supported runtimes

`3.11`, `3.12`, `3.13`, `3.14`. Anything else fails.

`3.11` also prints a `::warning::` and carries on. It is the last Amazon Linux 2
Python runtime and AWS retires it on 2027-06-30, but it works today, so the
action lets the build through.

This list is kept by hand, because AWS has no API to ask for the supported
runtime set. It needs an edit here whenever AWS adds a version.

### `packager-version` is a floor as well as a default

Below `1.0.0`, `package-python-function` has no `--report` flag, and the action
reads every one of its outputs out of that report. An older version cannot
work.

The packager runs under its own interpreter, which `uv` fetches and which has
to be Python ≥ 3.11. That is unrelated to `python-version`: that input names
the Lambda runtime you are targeting, and the packager only reads files out of
the built venv, never imports them.

## Outputs

| Output | Description |
|---|---|
| `zip-path` | **Absolute** path to the zip on the runner. Pass it to Terraform unchanged. |
| `zip-sha256` | SHA-256 of the zip. The same inputs give you the same hash, so you can skip redeploying an unchanged function. |
| `package-size-bytes` | Size of the zip on disk. |
| `uncompressed-bytes` | Unzipped size - **this** is the figure AWS's 250 MiB deployment package limit applies to, not `package-size-bytes`. |
| `nested-zip` | `true` when the packager's >250 MiB fallback kicked in and nested the dependencies in an inner zip. |

## Artifacts

Artifact upload is off by default. The common case is a Terraform step in the
same job reading the zip straight off the filesystem, and turning upload on
would cost you time and storage for nothing.

`actions/upload-artifact` artifacts are immutable and **error on same-name
collisions**, so a caller running a matrix has to give every job a distinct
name. Leave `artifact-name` empty and the action derives one that already is:

```
<distribution-name>-<platform>-py<python-version>
```

for example `my_app-aarch64-manylinux2014-py3.13`. The distribution name comes
from the packager's own report, so it matches the zip's filename instead of
being worked out a second time here.

## License

MIT - see [LICENSE](LICENSE).
