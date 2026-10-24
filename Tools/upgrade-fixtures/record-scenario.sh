#!/usr/bin/env bash
set -euo pipefail
current="$1"
historical="$2"
scenario="$3"
shift 3
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
unset SDKROOT
source "$current/scripts/build-paths.sh"
encryptedmemories_acquire_build_lock "upgrade-fixture-$scenario"
release="${UPGRADE_FIXTURE_RELEASE:?Use regenerate.sh to select the stable release}"
[[ "$(git -C "$historical" rev-parse "refs/tags/$release^{commit}")" == "$(git -C "$historical" rev-parse HEAD)" ]] || {
  echo 'Historical checkout differs from the requested release tag.' >&2
  exit 65
}
changes="$(git -C "$historical" diff HEAD --name-only)"
[[ "$changes" == "Packages/EncryptedMemoriesKit/Package.swift" ]] || {
  echo 'Historical tracked sources must remain unchanged outside the recorder target declaration.' >&2
  exit 65
}
sdk="$(python3 - "$historical/scripts/update-proton-sdk.sh" <<'EOF'
import re, sys
from pathlib import Path
match = re.search(r'TAG="\$\{1:-([^}]+)\}"', Path(sys.argv[1]).read_text())
if not match:
    raise SystemExit('Historical SDK default could not be determined')
print(match.group(1))
EOF
)"
release_build="$ENCRYPTED_MEMORIES_BUILD_ROOT/UpgradeFixtures.noindex/$release"
historical_build="$release_build/sdk-$sdk"
fixture_build="$release_build"
if [[ -n "${UPGRADE_FIXTURE_RUN_ID:-}" ]]; then
  [[ "$UPGRADE_FIXTURE_RUN_ID" =~ ^run\.[A-Za-z0-9]+$ ]] || { echo 'Invalid recording run ID.' >&2; exit 64; }
  fixture_build="$fixture_build/$UPGRADE_FIXTURE_RUN_ID"
fi
mkdir -p "$fixture_build"
if [[ "${1:-}" != "--skip-build" ]]; then
  disposable="$(mktemp -d "$fixture_build/sdk-restore.XXXXXX")"
  /usr/bin/env -i HOME="$HOME" PATH="$PATH" DEVELOPER_DIR="$DEVELOPER_DIR" ENCRYPTED_MEMORIES_BUILD_ROOT="$disposable" \
    bash "$historical/scripts/update-proton-sdk.sh" "$sdk"
  /usr/bin/env -i HOME="$HOME" PATH="$PATH" DEVELOPER_DIR="$DEVELOPER_DIR" \
    xcrun clang -dynamiclib -Wall -Wextra -Werror -O2 "$current/Tools/upgrade-fixtures/Recorder/observe.c" "$current/Tools/upgrade-fixtures/Recorder/temporary.m" -framework Foundation -lsqlite3 -o "$fixture_build/observe.dylib"
  python3 - "$fixture_build/recording.json" "$release" "$sdk" "$(git -C "$historical" rev-parse HEAD)" <<'EOF'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps(dict(release=sys.argv[2], sdk=sys.argv[3], commit=sys.argv[4])))
EOF
  /usr/bin/env -i HOME="$HOME" PATH="$PATH" DEVELOPER_DIR="$DEVELOPER_DIR" \
    xcrun swift build --package-path "$historical/Packages/EncryptedMemoriesKit" --scratch-path "$historical_build/SPM.noindex" \
      --cache-path "$historical_build/SwiftPMCache.noindex" --force-resolved-versions --product UpgradeFixtureRecorder
fi
binary="$historical_build/SPM.noindex/debug/UpgradeFixtureRecorder"
[[ -x "$binary" && -f "$fixture_build/observe.dylib" ]] || { echo 'Build the recorder first.' >&2; exit 66; }
recorded="$fixture_build/recorded/$scenario"
# Some records store the path of the data tree. Keep it in the shared folder, which names no person.
data_base="${UPGRADE_FIXTURE_DATA_BASE:?Use regenerate.sh to select the data root}"
data="$data_base/$release/${UPGRADE_FIXTURE_RUN_ID:-run}/$scenario"
[[ ! -e "$recorded" && ! -e "$data" ]] || { echo 'Use a fresh recording destination.' >&2; exit 73; }
mkdir -p "$recorded" "$data/Temporary"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' /usr/bin/env -i \
  HOME="$HOME" PATH="$PATH" DEVELOPER_DIR="$DEVELOPER_DIR" TMPDIR="$data/Temporary/" \
  DYLD_INSERT_LIBRARIES="$fixture_build/observe.dylib" UPGRADE_RECORD_ROOT="$data" UPGRADE_RECORD_OUTPUT="$recorded" \
  UPGRADE_RECORD_ORACLE="$fixture_build/oracle-$scenario.json" "$binary" "$scenario"
[[ -s "$recorded/events.jsonl" ]] || { echo 'Observer recorded no writes.' >&2; exit 70; }
