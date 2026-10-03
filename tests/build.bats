#!/usr/bin/env bats
#
# Unit tests for build.sh's pure helpers. Sourcing the script defines its
# functions without running the pipeline, so these take milliseconds and need
# no uv, no network and no fixture.

setup() {
  source "$BATS_TEST_DIRNAME/../build.sh"
}

# --- platform_architecture ---

@test "platform_architecture maps the arm64 platform" {
  run platform_architecture aarch64-manylinux2014
  [ "$status" -eq 0 ]
  [ "$output" = "arm64" ]
}

@test "platform_architecture maps the x86_64 platform" {
  run platform_architecture x86_64-manylinux2014
  [ "$status" -eq 0 ]
  [ "$output" = "x86_64" ]
}

@test "platform_architecture rejects a manylinux variant we do not support" {
  run platform_architecture aarch64-manylinux_2_28
  [ "$status" -ne 0 ]
}

@test "platform_architecture rejects a bare architecture" {
  run platform_architecture arm64
  [ "$status" -ne 0 ]
}

@test "platform_architecture rejects an empty platform" {
  run platform_architecture ""
  [ "$status" -ne 0 ]
}

# --- python_version_runtime ---

@test "python_version_runtime names the AWS runtime for every supported version" {
  for version in $SUPPORTED_PYTHON_VERSIONS; do
    run python_version_runtime "$version"
    [ "$status" -eq 0 ]
    [ "$output" = "python$version" ]
  done
}

@test "python_version_runtime rejects a deprecated runtime" {
  run python_version_runtime 3.10
  [ "$status" -ne 0 ]
}

@test "python_version_runtime rejects a preview runtime" {
  run python_version_runtime 3.15
  [ "$status" -ne 0 ]
}

@test "python_version_runtime rejects a runtime-prefixed value" {
  run python_version_runtime python3.13
  [ "$status" -ne 0 ]
}

@test "python_version_runtime rejects a patch version" {
  run python_version_runtime 3.13.1
  [ "$status" -ne 0 ]
}

# --- python_version_deprecation_date ---

@test "python_version_deprecation_date dates the last Amazon Linux 2 runtime" {
  run python_version_deprecation_date 3.11
  [ "$status" -eq 0 ]
  [ "$output" = "2027-06-30" ]
}

@test "python_version_deprecation_date says nothing for a current runtime" {
  run python_version_deprecation_date 3.13
  [ "$status" -ne 0 ]
  [ "$output" = "" ]
}

# --- source_date_epoch_is_valid ---

@test "source_date_epoch_is_valid accepts the zip epoch itself" {
  run source_date_epoch_is_valid 315532800
  [ "$status" -eq 0 ]
}

@test "source_date_epoch_is_valid accepts a present-day timestamp" {
  run source_date_epoch_is_valid 1780000000
  [ "$status" -eq 0 ]
}

@test "source_date_epoch_is_valid rejects a timestamp before the zip epoch" {
  run source_date_epoch_is_valid 315532799
  [ "$status" -ne 0 ]
}

@test "source_date_epoch_is_valid rejects zero" {
  run source_date_epoch_is_valid 0
  [ "$status" -ne 0 ]
}

@test "source_date_epoch_is_valid rejects a negative timestamp" {
  run source_date_epoch_is_valid -1
  [ "$status" -ne 0 ]
}

@test "source_date_epoch_is_valid rejects a non-integer" {
  run source_date_epoch_is_valid 1780000000.5
  [ "$status" -ne 0 ]
}

@test "source_date_epoch_is_valid rejects a non-number" {
  run source_date_epoch_is_valid yesterday
  [ "$status" -ne 0 ]
}

@test "source_date_epoch_is_valid rejects an empty value" {
  run source_date_epoch_is_valid ""
  [ "$status" -ne 0 ]
}

@test "source_date_epoch_is_valid reads a zero-padded value as decimal, not octal" {
  run source_date_epoch_is_valid 0315532800
  [ "$status" -eq 0 ]
}

# --- format_bytes ---

@test "format_bytes leaves small counts in bytes" {
  run format_bytes 0
  [ "$output" = "0 B" ]
  run format_bytes 1023
  [ "$output" = "1023 B" ]
}

@test "format_bytes switches to KiB at the boundary" {
  run format_bytes 1024
  [ "$output" = "1.0 KiB" ]
}

@test "format_bytes formats a realistic zip size" {
  run format_bytes 130169
  [ "$output" = "127.1 KiB" ]
}

@test "format_bytes formats AWS's unzipped limit as a round 250 MiB" {
  run format_bytes "$AWS_LAMBDA_MAX_UNZIP_SIZE"
  [ "$output" = "250.0 MiB" ]
}

@test "format_bytes stops at GiB rather than making up a larger unit" {
  run format_bytes $((5 * 1024 * 1024 * 1024))
  [ "$output" = "5.0 GiB" ]
}
