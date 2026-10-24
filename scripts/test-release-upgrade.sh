#!/usr/bin/env bash
# Upload-free rehearsal and CI entry point. Invoke local runs through build-turn.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/build-paths.sh"
encryptedmemories_acquire_build_lock release-upgrade
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
python3 "$ROOT/scripts/upgrade-test/run_journey.py" \
  --repo "$ROOT" --automation "$ROOT" --root "$ENCRYPTED_MEMORIES_BUILD_ROOT/UpgradeCheck" "$@"
