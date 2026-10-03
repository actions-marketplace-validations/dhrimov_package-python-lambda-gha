#!/usr/bin/env bash
#
# Package a Python project into an AWS Lambda deployment zip.
#
#   build.sh --input <dir> --output <dir> --python <version> --platform <platform>
#
# Builds the project as a wheel, installs it together with its locked
# dependencies into a throwaway venv built for the Lambda platform, and hands
# that venv to package-python-function, which writes a reproducible zip named
# after the project.
#
# Everything that talks to GitHub Actions lives here rather than in action.yml:
# the runner guard, the input checks, the collapsible ::group:: sections,
# and the $GITHUB_OUTPUT writes. Sourcing this file defines its functions
# without running the pipeline, which is how the bats suite tests the pure
# helpers below.

set -euo pipefail

# --- constants --------------------------------------------------------------

DEFAULT_PACKAGER_VERSION="1.0.0"

# AWS Lambda's unzipped deployment package limit, in bytes: exactly 250 MiB.
AWS_LAMBDA_MAX_UNZIP_SIZE=262144000

# The zip format's own epoch, 1980-01-01T00:00:00Z. No timestamp below it can
# be stored in a zip entry, so no SOURCE_DATE_EPOCH below it is usable.
MIN_SOURCE_DATE_EPOCH=315532800

# The AWS Lambda Python runtimes this action supports, checked by hand against
# AWS's Lambda runtimes docs. There is no API to ask for the supported set, so
# this list needs an edit whenever AWS adds a version.
SUPPORTED_PYTHON_VERSIONS="3.11 3.12 3.13 3.14"

# --- pure helpers -----------------------------------------------------------
#
# Everything in this section depends only on its arguments, so the bats suite
# can source this file and call it directly.

# The Lambda CPU architecture a uv target platform builds for. Doubles as the
# platform allow-list: an unsupported platform has no architecture to name.
platform_architecture() {
  case "$1" in
    aarch64-manylinux2014) printf 'arm64' ;;
    x86_64-manylinux2014) printf 'x86_64' ;;
    *) return 1 ;;
  esac
}

# The AWS Lambda runtime identifier for a target Python version, e.g.
# 3.13 -> python3.13. Fails for any version outside the supported set.
python_version_runtime() {
  case " $SUPPORTED_PYTHON_VERSIONS " in
    *" $1 "*) printf 'python%s' "$1" ;;
    *) return 1 ;;
  esac
}

# The date AWS retires a runtime that still works but is on its way out, or
# failure for one with no announced end. 3.11 is the last Amazon Linux 2 Python
# runtime. It warns rather than fails: AWS still supports it, and this action's
# job is catching drift the caller didn't mean to introduce, not pushing an
# upgrade schedule. (Amazon Linux 2's own EOL, Jun 30 2026, is a different date
# and is not a runtime deprecation.)
python_version_deprecation_date() {
  case "$1" in
    3.11) printf '2027-06-30' ;;
    *) return 1 ;;
  esac
}

# Whether a SOURCE_DATE_EPOCH value is usable: a non-negative integer no
# earlier than the zip epoch. The packager checks it too, but it runs last, so
# a bad value would otherwise cost a full venv build first.
source_date_epoch_is_valid() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  ((10#$1 >= MIN_SOURCE_DATE_EPOCH))
}

# A byte count in the nearest binary unit with one decimal place, e.g.
# 130169 -> "127.1 KiB". For reading only, never parsed.
format_bytes() {
  local bytes="$1"
  if ((bytes < 1024)); then
    printf '%d B' "$bytes"
    return 0
  fi

  local units=(KiB MiB GiB)
  local index=0
  local scale=1024
  while ((index < ${#units[@]} - 1 && bytes >= scale * 1024)); do
    scale=$((scale * 1024))
    index=$((index + 1))
  done

  printf '%d.%d %s' $((bytes / scale)) $((bytes * 10 / scale % 10)) "${units[index]}"
}

# --- logging ----------------------------------------------------------------

log() {
  printf '\n==> %s\n' "$*"
}

# Pipeline stages become collapsible sections in the Actions log.
group() {
  printf '\n::group::%s\n' "$*"
}

endgroup() {
  printf '::endgroup::\n'
}

warn() {
  printf '::warning::%s\n' "$*" >&2
}

usage() {
  cat <<EOF
Usage: ${0##*/} --input <dir> --output <dir> --python <version> --platform <platform>
                [--build-dir <dir>] [--packager-version <version>]
                [--fail-on-non-linux <true|false>]

  --input      directory containing the project's pyproject.toml
  --output     directory to write the zip into (created if missing)
  --python     Python version to build against, one of:
               $SUPPORTED_PYTHON_VERSIONS
  --platform   uv target platform, one of: aarch64-manylinux2014,
               x86_64-manylinux2014
  --build-dir  scratch directory for intermediates, which build.sh takes over
               completely: it is deleted, not emptied, before and after every
               build. Never point it at a directory holding anything you want
               to keep, and never share it between builds running at the same
               time - each one deletes the other's work in progress. Defaults
               to <input>/build, on those same terms.
  --packager-version
               package-python-function version to package with. Defaults to
               $DEFAULT_PACKAGER_VERSION. Earlier releases are 0.0.x with no
               --report flag, and are not checked for: an older pin fails at
               the packaging step, after the venv is built.
  --fail-on-non-linux
               refuse to run on a non-Linux GitHub Actions runner. Linux
               runners are the only ones this action is tested on. Defaults
               to true.

The first four are required: a default platform would quietly pick the
architecture of every compiled dependency in the package.

Example:
  ${0##*/} --input . --output terraform --python 3.13 --platform aarch64-manylinux2014
EOF
}

# A usage error: the caller passed the wrong flags.
die() {
  echo "error: $*" >&2
  usage >&2
  exit 1
}

# A validation error: the flags parse, but the build they ask for cannot work.
# Annotated so it shows up on the Actions job summary and not only in the log,
# and raised before any uv/uvx work starts.
fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

# The zip's SHA-256, lowercase hex. sha256sum ships with coreutils and is
# always there on the Linux runners this action targets. The shasum fallback
# keeps the script runnable on a macOS dev machine.
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# --- main -------------------------------------------------------------------

main() {
  INPUT=""
  OUTPUT=""
  PYTHON_VERSION=""
  PLATFORM=""
  BUILD_DIR=""
  PACKAGER_VERSION="$DEFAULT_PACKAGER_VERSION"
  FAIL_ON_NON_LINUX="true"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --input | --output | --python | --platform | --build-dir | --packager-version | --fail-on-non-linux)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        case "$1" in
          --input) INPUT="$2" ;;
          --output) OUTPUT="$2" ;;
          --python) PYTHON_VERSION="$2" ;;
          --platform) PLATFORM="$2" ;;
          --build-dir) BUILD_DIR="$2" ;;
          --packager-version) PACKAGER_VERSION="$2" ;;
          --fail-on-non-linux) FAIL_ON_NON_LINUX="$2" ;;
        esac
        shift 2
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$INPUT" ]] || die "missing --input"
  [[ -n "$OUTPUT" ]] || die "missing --output"
  [[ -n "$PYTHON_VERSION" ]] || die "missing --python"
  [[ -n "$PLATFORM" ]] || die "missing --platform"
  [[ -n "$PACKAGER_VERSION" ]] || die "missing --packager-version"

  case "$FAIL_ON_NON_LINUX" in
    true | false) ;;
    *) die "--fail-on-non-linux must be true or false, got: $FAIL_ON_NON_LINUX" ;;
  esac

  # --- guard rails ---
  #
  # Everything below runs before the first uv call, so a build that cannot work
  # fails in seconds rather than after a full venv install.

  # RUNNER_OS is set by GitHub Actions and unset for a local run, where there
  # is no runner to refuse.
  if [[ "$FAIL_ON_NON_LINUX" == "true" && -n "${RUNNER_OS:-}" && "$RUNNER_OS" != "Linux" ]]; then
    fail "this action packages Lambda zips on Linux runners only, but RUNNER_OS is $RUNNER_OS." \
      "Linux runners are the only ones this action is tested on, and a build that goes wrong on" \
      "another one goes wrong quietly: a package that deploys fine and then breaks at Lambda" \
      "runtime. Set fail-on-non-linux: false to override."
  fi

  local architecture
  architecture="$(platform_architecture "$PLATFORM")" ||
    fail "unsupported platform: $PLATFORM. Expected aarch64-manylinux2014 or x86_64-manylinux2014."

  local runtime
  runtime="$(python_version_runtime "$PYTHON_VERSION")" ||
    fail "unsupported python-version: $PYTHON_VERSION. Expected one of: $SUPPORTED_PYTHON_VERSIONS."

  local deprecation_date
  if deprecation_date="$(python_version_deprecation_date "$PYTHON_VERSION")"; then
    warn "$runtime is on its way out: AWS retires it on $deprecation_date." \
      "Packaging carries on - it is still a supported runtime today."
  fi

  # Passed through untouched rather than unset or overridden, so a caller who
  # set it on purpose keeps it working.
  if [[ -n "${SOURCE_DATE_EPOCH:-}" ]] && ! source_date_epoch_is_valid "$SOURCE_DATE_EPOCH"; then
    fail "SOURCE_DATE_EPOCH must be an integer >= $MIN_SOURCE_DATE_EPOCH (1980-01-01, the zip" \
      "format's epoch), got: $SOURCE_DATE_EPOCH"
  fi

  # jq reads the packager's report. All three come preinstalled on the
  # GitHub-hosted runners, so this check is really for local runs.
  local tool
  for tool in uv uvx jq; do
    command -v "$tool" >/dev/null 2>&1 ||
      die "required tool not found on PATH: $tool"
  done

  [[ -f "$INPUT/pyproject.toml" ]] || die "no pyproject.toml in: $INPUT"

  # Resolve every path now, so the uv --directory below cannot shift them.
  INPUT="$(cd "$INPUT" && pwd)"
  mkdir -p "$OUTPUT"
  OUTPUT="$(cd "$OUTPUT" && pwd)"

  mkdir -p "${BUILD_DIR:=$INPUT/build}"
  BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"

  # Everything below deletes this directory, so refuse the two paths that would
  # take the project or the finished zip down with it.
  [[ "$BUILD_DIR" != "$INPUT" ]] || die "--build-dir must not be the input directory"
  [[ "$BUILD_DIR" != "$OUTPUT" ]] || die "--build-dir must not be the output directory"

  # --- pipeline ---

  trap clean_build_dir EXIT
  clean_build_dir
  mkdir -p "$BUILD_DIR"

  group "[1/5] exporting locked dependencies"
  uv export \
    --directory "$INPUT" \
    --frozen \
    --no-dev \
    --no-editable \
    --no-emit-project \
    -o "$BUILD_DIR/requirements.txt"
  endgroup

  group "[2/5] building wheel"
  uv build --directory "$INPUT" --wheel -o "$BUILD_DIR/dist"
  endgroup

  group "[3/5] creating venv (python $PYTHON_VERSION)"
  uv venv --python "$PYTHON_VERSION" "$BUILD_DIR/venv"
  endgroup

  group "[4/5] installing wheel and dependencies for $PLATFORM ($architecture)"
  uv pip install \
    --python "$BUILD_DIR/venv/bin/python" \
    --python-platform "$PLATFORM" \
    --only-binary=:all: \
    --no-installer-metadata \
    --no-compile-bytecode \
    "$BUILD_DIR"/dist/*.whl \
    -r "$BUILD_DIR/requirements.txt"
  endgroup

  local report="$BUILD_DIR/report.json"

  group "[5/5] packaging"
  uvx "package-python-function@$PACKAGER_VERSION" \
    "$BUILD_DIR/venv" \
    --project "$INPUT/pyproject.toml" \
    --output-dir "$OUTPUT" \
    --report "$report"
  endgroup

  report_outputs "$report"
}

# Every intermediate lives under the build directory, so cleanup has one
# predictable target and never reaches a path outside it. It takes the
# directory itself, though, not just its contents: two builds sharing one
# --build-dir would delete each other's work in progress. Keeping it
# exclusive is the caller's job - see usage().
clean_build_dir() {
  rm -rf "$BUILD_DIR"
}

# Turn the packager's report into the action's outputs. Nothing here works out
# the zip's filename again or globs the output directory - the packager already
# knows what it wrote, and says so.
report_outputs() {
  local report="$1"

  # The packager writes the report only after packaging has succeeded, so a
  # missing report means something went wrong that set -e did not catch.
  [[ -f "$report" ]] || fail "packaging reported success but wrote no report at $report"

  local zip_path distribution_name output_bytes uncompressed_bytes nested_zip zip_sha256
  zip_path="$(jq -er '.output_file' "$report")"
  distribution_name="$(jq -er '.distribution_name' "$report")"
  output_bytes="$(jq -er '.output_bytes' "$report")"
  uncompressed_bytes="$(jq -er '.uncompressed_bytes' "$report")"
  # compressed_bytes is left unread on purpose: it is measured on the temporary
  # dependencies zip, and only matches output_bytes when the nested strategy
  # did not run.
  nested_zip="$(jq -er 'if .nested_zip then "true" else "false" end' "$report")"

  zip_sha256="$(file_sha256 "$zip_path")"

  log "packaged $distribution_name -> $zip_path"
  log "zip $(format_bytes "$output_bytes"), $(format_bytes "$uncompressed_bytes") unzipped"
  if [[ "$nested_zip" == "true" ]]; then
    # The packager nests the dependencies in an inner zip and writes a loader,
    # so the unzipped size AWS measures is the outer zip's, not this figure.
    log "nested-zip fallback kicked in: unzipped size is over AWS's 250 MiB limit"
  else
    log "$(format_bytes $((AWS_LAMBDA_MAX_UNZIP_SIZE - uncompressed_bytes))) of headroom under AWS's 250 MiB limit"
  fi

  # Unset on a local run, where there is no step to report to.
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0

  {
    echo "zip-path=$zip_path"
    echo "zip-sha256=$zip_sha256"
    echo "package-size-bytes=$output_bytes"
    echo "uncompressed-bytes=$uncompressed_bytes"
    echo "nested-zip=$nested_zip"
    # Not a declared action output. action.yml uses it to build the default
    # artifact name from the same place the zip's filename comes from.
    echo "distribution-name=$distribution_name"
  } >>"$GITHUB_OUTPUT"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
