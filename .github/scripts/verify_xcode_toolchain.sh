#!/usr/bin/env bash
# Verify the reviewed hosted toolchain before dependencies or upgrade caches are used.
set -euo pipefail
source .github/scripts/release_failure.sh
# The reviewed pins are the defaults of the prepare-apple-build action. The caller passes them; this script has none.
[[ -n "${EXPECTED_XCODE_VERSION:-}" && -n "${EXPECTED_XCODE_BUILD:-}" ]] || release_fail toolchain \
  "EXPECTED_XCODE_VERSION or EXPECTED_XCODE_BUILD is missing or empty." \
  "Pass both reviewed pins from the xcode-version and xcode-build inputs of .github/actions/prepare-apple-build."
expected_version="$EXPECTED_XCODE_VERSION"
expected_build="$EXPECTED_XCODE_BUILD"
[[ -n "${DEVELOPER_DIR:-}" && -d "$DEVELOPER_DIR" ]] || release_fail toolchain \
  "The selected Xcode developer directory is missing." \
  "Select the reviewed Xcode installation from the hosted image inventory."
if ! xcode_output="$(xcodebuild -version)"; then
  printf '%s\n' "$xcode_output"
  release_fail toolchain "xcodebuild -version failed for the selected Xcode." \
    "Check the selected Xcode installation on the hosted image."
fi
printf 'DEVELOPER_DIR=%s\n%s\n' "$DEVELOPER_DIR" "$xcode_output"
xcode_version="$(awk '/^Xcode / { print $2; exit }' <<< "$xcode_output")"
xcode_build="$(awk '/^Build version / { print $3; exit }' <<< "$xcode_output")"
[[ "$xcode_version" == "$expected_version" && "$xcode_build" == "$expected_build" ]] || release_fail toolchain \
  "The runner uses Xcode '${xcode_version:-unknown}' build '${xcode_build:-unknown}'; expected '$expected_version' build '$expected_build'." \
  "Select the reviewed version and build, or update both pins in a reviewed change."
