#!/bin/bash
# Restores a reviewed Proton Drive SDK tag and applies the matching local patches.
# The script reports the ProtonCore pin but does not edit project.yml or build the app.
#
# Usage: scripts/update-proton-sdk.sh [<tag>]   (defaults to the reviewed release)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SDK_DIR="Vendor/sdk-swift"
REPO="https://github.com/ProtonDriveApps/sdk-swift.git"
TAG="${1:-0.32.1}"
PATCH_DIR="$ROOT/VendorPatches/sdk-swift/$TAG"
PIN_FILE="$PATCH_DIR/UPSTREAM_COMMIT"
shopt -s nullglob
PATCHES=("$PATCH_DIR"/*.patch)
if [[ ! -f "$PIN_FILE" || ${#PATCHES[@]} -eq 0 ]]; then
  echo "ERROR: no reviewed Encrypted Memories patch set exists for sdk-swift $TAG." >&2
  echo "Create and verify VendorPatches/sdk-swift/$TAG before changing the vendored checkout." >&2
  exit 1
fi

if [ ! -d "$SDK_DIR/.git" ]; then
  echo "Cloning sdk-swift..."
  git clone "$REPO" "$SDK_DIR"
fi

git -C "$SDK_DIR" fetch --tags --quiet "$REPO"

EXPECTED_COMMIT="$(tr -d '[:space:]' < "$PIN_FILE")"
[[ "$EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  echo "ERROR: $PIN_FILE must contain one lowercase 40-character commit hash." >&2
  exit 1
}

ACTUAL_COMMIT="$(git -C "$SDK_DIR" rev-parse "refs/tags/$TAG^{commit}")"
[[ "$ACTUAL_COMMIT" == "$EXPECTED_COMMIT" ]] || {
  echo "ERROR: sdk-swift tag $TAG resolves to $ACTUAL_COMMIT, expected $EXPECTED_COMMIT." >&2
  exit 1
}

echo "Checking out sdk-swift $TAG at $EXPECTED_COMMIT..."
git -C "$SDK_DIR" checkout --quiet --force "$EXPECTED_COMMIT"
# Network-backed worktrees can briefly retain the previous checkout's cached stat data. Force Git
# to revalidate every tracked file before applying the reviewed patch set.
git -C "$SDK_DIR" update-index --really-refresh
git -C "$SDK_DIR" diff-files --quiet

# Rename the upstream photo client before applying app-specific patches.
CLIENT_PARENT="$SDK_DIR/Sources/Client"
LEGACY_CLIENT_DIR="$(find "$CLIENT_PARENT" -mindepth 1 -maxdepth 1 -type d \
  -name '*PhotosClient' ! -name 'EncryptedMemoriesClient' -print -quit)"
if [[ -n "$LEGACY_CLIENT_DIR" ]]; then
  LEGACY_CLIENT_NAME="$(basename "$LEGACY_CLIENT_DIR")"
  ENCRYPTED_CLIENT_DIR="$CLIENT_PARENT/EncryptedMemoriesClient"
  mv "$LEGACY_CLIENT_DIR" "$ENCRYPTED_CLIENT_DIR"

  LEGACY_CLIENT_FILE="$ENCRYPTED_CLIENT_DIR/$LEGACY_CLIENT_NAME.swift"
  if [[ -f "$LEGACY_CLIENT_FILE" ]]; then
    mv "$LEGACY_CLIENT_FILE" "$ENCRYPTED_CLIENT_DIR/EncryptedMemoriesClient.swift"
  fi

  LEGACY_CLIENT_NAME="$LEGACY_CLIENT_NAME" find "$ENCRYPTED_CLIENT_DIR" -type f -name '*.swift' -print0 \
    | LEGACY_CLIENT_NAME="$LEGACY_CLIENT_NAME" xargs -0 perl -pi -e '
        s/\Q$ENV{LEGACY_CLIENT_NAME}\E/EncryptedMemoriesClient/g;
        s/\Qfree$ENV{LEGACY_CLIENT_NAME}\E/freeEncryptedMemoriesClient/g;
      '
fi
git -C "$SDK_DIR" add -A

echo "Applying versioned Encrypted Memories SDK fixes..."
for PATCH in "${PATCHES[@]}"; do
  # A forced tag checkout resets tracked changes but leaves files that an earlier patch introduced.
  # Remove only paths that this reviewed target patch declares as creations, after validating that
  # every path is relative and remains below the vendored checkout.
  while IFS= read -r CREATED_PATH; do
    case "$CREATED_PATH" in
      ""|/*|../*|*/../*)
        echo "ERROR: unsafe created path in $PATCH: $CREATED_PATH" >&2
        exit 1
        ;;
    esac
    rm -f -- "$SDK_DIR/$CREATED_PATH"
  done < <(git apply --summary "$PATCH" | sed -n 's/^ create mode [0-9][0-9]* //p')

  # Versioned patches use zero context. This keeps the patch itself free of context-marker
  # trailing spaces so the repository-wide `git diff --check` gate remains meaningful.
  # The forced exact-tag checkout and deterministic client rename supply the reviewed baseline.
  git -C "$SDK_DIR" apply --check --unidiff-zero "$PATCH"
  git -C "$SDK_DIR" apply --unidiff-zero "$PATCH"
  # Stage patch-owned changes inside the nested checkout so its dirty state remains reviewable.
  git -C "$SDK_DIR" add -A
done

echo "Applying local SDK path-package patch..."
if ! grep -q 'sdkResourceLibrarySearchPath' "$SDK_DIR/Package.swift"; then
  perl -0pi -e 's~import PackageDescription~import Foundation\nimport PackageDescription\n\nlet packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path\nlet sdkResourceLibrarySearchPath = "-L\\(packageDirectory)/Resources"~' "$SDK_DIR/Package.swift"
fi
perl -0pi -e 's~\n\s*\.unsafeFlags\(\[\n\s*// path used in normal builds\n\s*"-L\$\{BUILD_DIR\}/\.\./\.\./SourcePackages/checkouts/sdk-swift/Resources",\n\s*// path used in archive builds\n\s*"-L\$\{BUILD_DIR\}/\.\./\.\./\.\./\.\./\.\./SourcePackages/checkouts/sdk-swift/Resources",\n\s*\]\),~\n                .unsafeFlags([sdkResourceLibrarySearchPath]),~g' "$SDK_DIR/Package.swift"
perl -0pi -e 's~"-llibbootstrapperdll\.osx-arm64\.o",\n\s*"-llibbootstrapperdll\.osx-x64\.o"~"-llibbootstrapperdll.osx-universal.o"~' "$SDK_DIR/Package.swift"
lipo -create \
  "$SDK_DIR/Resources/libbootstrapperdll.osx-arm64.o" \
  "$SDK_DIR/Resources/libbootstrapperdll.osx-x64.o" \
  -output "$SDK_DIR/Resources/libbootstrapperdll.osx-universal.o"

# The vendored test target links ProtonCore GoLibs with a version range so the app remains the only
# exact pin. Seed the standalone lock from the committed merged lock so `swift test` in Vendor/sdk-swift
# resolves the same ProtonCore revision as the app instead of floating to a newer release.
cp "$ROOT/BuildSupport/Package.resolved" "$SDK_DIR/Package.resolved"

echo "Clearing local Xcode module caches that may reference the previous SDK..."
source "$ROOT/scripts/build-paths.sh"
rm -rf "$ENCRYPTED_MEMORIES_BUILD_ROOT/DD.noindex" \
       "$ENCRYPTED_MEMORIES_BUILD_ROOT/DD.device.noindex" \
       "$ENCRYPTED_MEMORIES_BUILD_ROOT/DD.ios.noindex" \
       "$ENCRYPTED_MEMORIES_BUILD_ROOT/DD.tests.ios.noindex" \
       "$ENCRYPTED_MEMORIES_BUILD_ROOT/core-gate-dd.noindex" \
       "$ENCRYPTED_MEMORIES_SPM_SCRATCH" \
       "$ENCRYPTED_MEMORIES_SDK_SCRATCH" \
       "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES" \
       "$ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE"
# Legacy in-repo build dirs are non-canonical and may sit on a network volume. Leave them untouched:
# recursively deleting a large artifact tree there can block indefinitely and is not part of the SDK update.
for LEGACY_BUILD_DIR in "$ROOT/build" "$ROOT/Packages/EncryptedMemoriesKit/.build"; do
  if [[ -e "$LEGACY_BUILD_DIR" ]]; then
    echo "WARNING: non-canonical build directory left untouched: $LEGACY_BUILD_DIR" >&2
  fi
done

CORE=$(grep -o 'protoncore_ios.git", exact: "[^"]*"' "$SDK_DIR/Package.swift" | grep -o '[0-9][0-9.]*' || true)
echo ""
echo "  sdk-swift now at: $TAG ($(git -C "$SDK_DIR" rev-parse --short HEAD))"
if [ -n "$CORE" ]; then
  echo "  REQUIRED ProtonCore exactVersion: $CORE"
else
  echo "  ProtonCore: not pinned by the SDK; project.yml keeps the app's own exactVersion."
fi
echo ""
echo "Next:"
if [ -n "$CORE" ]; then
  echo "  1. Set project.yml -> packages.ProtonCore.exactVersion to $CORE (if different)."
else
  echo "  1. The ProtonCore version in project.yml is chosen by the app."
fi
echo "  2. Update the clone hint in .gitignore to $TAG."
echo "  3. xcodegen generate"
echo "  4. ./scripts/rebuild.sh"
