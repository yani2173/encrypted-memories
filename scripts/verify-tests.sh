#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
source "$ROOT/scripts/build-paths.sh"
if [[ -n "${ENCRYPTED_MEMORIES_TEST_BUILD_ROOT:-}" ]]; then
  PHOTOS_SCRATCH="$ENCRYPTED_MEMORIES_TEST_BUILD_ROOT/EncryptedMemoriesKit"
  SDK_SCRATCH="$ENCRYPTED_MEMORIES_TEST_BUILD_ROOT/sdk-swift"
else
  PHOTOS_SCRATCH="$ENCRYPTED_MEMORIES_SPM_SCRATCH"
  SDK_SCRATCH="$ENCRYPTED_MEMORIES_SDK_SCRATCH"
fi
export DEVELOPER_DIR

encryptedmemories_acquire_build_lock "verify-tests"

if [[ ! -f "$ROOT/Vendor/sdk-swift/Package.swift" ]]; then
  echo "[tests] Vendor/sdk-swift is missing; restore the pinned checkout before testing." >&2
  exit 66
fi

echo "[tests] Apple Vision SDK surface"
python3 "$ROOT/scripts/verify-apple-vision-sdk-surface.py"

echo "[tests] upgrade fixture release catalog"
python3 "$ROOT/scripts/tests/test_upgrade_fixture_corpus.py"

echo "[tests] EncryptedMemoriesKit"
xcrun swift test \
  --package-path "$ROOT/Packages/EncryptedMemoriesKit" \
  --scratch-path "$PHOTOS_SCRATCH" \
  --cache-path "$ENCRYPTED_MEMORIES_SWIFTPM_CACHE" \
  --force-resolved-versions \
  --no-parallel

# sdk-swift is a local path dependency, so SwiftPM does not execute its own test target while
# testing EncryptedMemoriesKit. Keep a separate invocation in the canonical gate or those tests vanish.
echo "[tests] vendored sdk-swift"
xcrun swift test \
  --package-path "$ROOT/Vendor/sdk-swift" \
  --scratch-path "$SDK_SCRATCH" \
  --cache-path "$ENCRYPTED_MEMORIES_SWIFTPM_CACHE" \
  --force-resolved-versions \
  --no-parallel

echo "[tests] all package suites passed"
