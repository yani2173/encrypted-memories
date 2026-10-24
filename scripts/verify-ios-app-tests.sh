#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
source "$ROOT/scripts/build-paths.sh"
DERIVED_DATA="${ENCRYPTED_MEMORIES_IOS_TEST_DERIVED_DATA:-$ENCRYPTED_MEMORIES_BUILD_ROOT/DD.tests.ios.noindex}"
# No argument runs the hosted tests. `ui` runs the UI tests, which launch the app on the offline fixture account and
# tap through it in the simulator.
case "${1:-hosted}" in
  hosted) TEST_TARGET="EncryptedMemoriesMobileTests" ;;
  ui) TEST_TARGET="EncryptedMemoriesMobileUITests" ;;
  *)
    echo "usage: $0 [hosted|ui]" >&2
    exit 64
    ;;
esac
SCHEME="${IOS_TEST_SCHEME:-$TEST_TARGET}"
ACTION="${IOS_TEST_ACTION:-test}"
PREPARED="${IOS_TEST_PREPARED:-0}"
case "$ACTION" in
  test|build-for-testing|test-without-building|boot-simulator) ;;
  *) echo "[ios-tests] unsupported IOS_TEST_ACTION." >&2; exit 64 ;;
esac
case "$PREPARED" in
  0|1) ;;
  *) echo "[ios-tests] IOS_TEST_PREPARED must be 0 or 1." >&2; exit 64 ;;
esac
if [[ -n "${IOS_TEST_PARALLEL_WORKERS:-}" && ! "$IOS_TEST_PARALLEL_WORKERS" =~ ^[1-9][0-9]*$ ]]; then
  echo "[ios-tests] IOS_TEST_PARALLEL_WORKERS must be a positive integer." >&2
  exit 64
fi
# The runner image decides which iPhone simulators exist, and Apple renames the lineup every year. A
# pinned device name therefore fails as "Unable to find a device matching the provided destination
# specifier" on a new image. Resolve an installed iPhone instead; IOS_TEST_DESTINATION still overrides it.
resolve_iphone_simulator() {
  xcrun simctl list devices available --json | python3 -c '
import json, re, sys

preferred = ["iPhone 17 Pro", "iPhone 17 Pro Max", "iPhone 17"]
names = {
    device["name"]
    for devices in json.load(sys.stdin)["devices"].values()
    for device in devices
    if device.get("isAvailable") and device["name"].startswith("iPhone")
}
for name in preferred:
    if name in names:
        print(name)
        raise SystemExit

def rank(name):
    model = re.search(r"\d+", name)
    return (int(model.group()) if model else 0, "Pro" in name, "Max" in name, name)

print(max(names, key=rank) if names else "")
'
}

# Resolve the requested runtime, or the newest installed iOS runtime for `OS=latest`.
resolve_simulator_udid() {
  xcrun simctl list devices available --json | python3 -c '
import json, re, sys

name = sys.argv[1]
requested_os = sys.argv[2]
devices_by_runtime = json.load(sys.stdin)["devices"]
if requested_os != "latest" and not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", requested_os):
    print("[ios-tests] simulator OS must be latest or a numeric version.", file=sys.stderr)
    raise SystemExit(64)
requested_version = tuple(int(part) for part in requested_os.split(".")) if requested_os != "latest" else None
best = None
for runtime, devices in devices_by_runtime.items():
    match = re.search(r"\.iOS-([0-9-]+)$", runtime)
    if not match:
        continue
    version = tuple(int(part) for part in match.group(1).split("-"))
    if requested_version is not None:
        matching_version = version + (0,) * max(0, 3 - len(version))
        if len(requested_version) < 3:
            matching_version = matching_version[:len(requested_version)]
        if matching_version != requested_version:
            continue
    for device in devices:
        if device.get("isAvailable") and device["name"] == name and (best is None or version > best[0]):
            best = (version, device["udid"])
print(best[1] if best else "")
' "$1" "${2-latest}"
}

if [[ -n "${IOS_TEST_DESTINATION:-}" ]]; then
  DESTINATION="$IOS_TEST_DESTINATION"
  SIMULATOR_UDID=""
  SIMULATOR_NAME=""
  SIMULATOR_OS="latest"
  DESTINATION_PLATFORM=""
  IFS=',' read -r -a DESTINATION_FIELDS <<< "$DESTINATION"
  # Bash read drops a trailing empty field; retain it for validation.
  if [[ "$DESTINATION" == *, ]]; then DESTINATION_FIELDS+=(""); fi
  for field in "${DESTINATION_FIELDS[@]}"; do
    if [[ "$field" != *=* ]]; then
      echo "[ios-tests] destination fields must use key=value; names containing commas require id=." >&2
      exit 64
    fi
    case "$field" in
      platform=*) DESTINATION_PLATFORM="${field#platform=}" ;;
      id=*)
        SIMULATOR_UDID="${field#id=}"
        if [[ -z "$SIMULATOR_UDID" ]]; then
          echo "[ios-tests] destination id cannot be empty." >&2
          exit 64
        fi
        ;;
      name=*) SIMULATOR_NAME="${field#name=}" ;;
      OS=*)
        SIMULATOR_OS="${field#OS=}"
        if [[ -z "$SIMULATOR_OS" ]]; then
          echo "[ios-tests] destination OS cannot be empty." >&2
          exit 64
        fi
        if [[ "$SIMULATOR_OS" != "latest" && ! "$SIMULATOR_OS" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
          echo "[ios-tests] simulator OS must be latest or a numeric version." >&2
          exit 64
        fi
        ;;
    esac
  done
  if [[ "$DESTINATION_PLATFORM" == "iOS Simulator" ]]; then
    if [[ -z "$SIMULATOR_UDID" && -n "$SIMULATOR_NAME" ]]; then
      SIMULATOR_UDID="$(resolve_simulator_udid "$SIMULATOR_NAME" "$SIMULATOR_OS")"
      if [[ -z "$SIMULATOR_UDID" ]]; then
        echo "[ios-tests] no available simulator for $SIMULATOR_NAME with OS=$SIMULATOR_OS." >&2
        exit 69
      fi
      # Pin xcodebuild to the same device that bootstatus waits for; preserve other destination fields.
      DESTINATION=""
      for field in "${DESTINATION_FIELDS[@]}"; do
        case "$field" in name=*|OS=*) continue ;; esac
        DESTINATION="${DESTINATION:+$DESTINATION,}$field"
      done
      DESTINATION="$DESTINATION,id=$SIMULATOR_UDID"
    fi
    SIMULATOR_NAME="${SIMULATOR_NAME:-$SIMULATOR_UDID}"
  else
    SIMULATOR_UDID=""
  fi
else
  SIMULATOR_NAME="$(resolve_iphone_simulator)"
  if [[ -z "$SIMULATOR_NAME" ]]; then
    echo "[ios-tests] no available iPhone simulator; install an iOS runtime or set IOS_TEST_DESTINATION." >&2
    exit 69
  fi
  SIMULATOR_UDID="$(resolve_simulator_udid "$SIMULATOR_NAME")"
  if [[ -n "$SIMULATOR_UDID" ]]; then
    # The booted device and the tested device must be the same, also when two simulators share the name.
    DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID"
  else
    echo "[ios-tests] no device ID for $SIMULATOR_NAME; xcodebuild boots the simulator itself."
    DESTINATION="platform=iOS Simulator,name=$SIMULATOR_NAME,OS=latest"
  fi
fi
export DEVELOPER_DIR

# CI starts the simulator at the beginning of the job, while the dependencies and the test bundles build, so the
# boot is done when the tests start. The wait below still covers a boot that has not finished.
if [[ "$ACTION" == "boot-simulator" ]]; then
  if [[ -z "$SIMULATOR_UDID" ]]; then
    echo "[ios-tests] no simulator to start."
    exit 0
  fi
  echo "[ios-tests] starting $SIMULATOR_NAME"
  # The test run reads this record and shuts down a device that it does not test, so that two simulators never run.
  if [[ -n "${IOS_TEST_BOOT_RECORD:-}" ]]; then echo "$SIMULATOR_UDID" > "$IOS_TEST_BOOT_RECORD" || true; fi
  xcrun simctl boot "$SIMULATOR_UDID" || echo "[ios-tests] the start failed; the test run boots the simulator itself."
  exit 0
fi

encryptedmemories_acquire_build_lock "verify-ios-app-tests ${1:-hosted}"

# CI prepares the pinned graph once for both test bundles. Local commands still generate and resolve it.
if [[ "$PREPARED" == "1" ]]; then
  cmp "$ROOT/BuildSupport/Package.resolved" \
    "$ROOT/EncryptedMemories.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
else
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "[ios-tests] xcodegen is required to generate EncryptedMemories.xcodeproj." >&2
    exit 69
  fi

  echo "[ios-tests] generating project"
  (cd "$ROOT" && xcodegen generate)
  encryptedmemories_pin_generated_project_packages "$ROOT"

  echo "[ios-tests] resolving pinned packages into shared cache"
  xcrun xcodebuild \
    -resolvePackageDependencies \
    -project "$ROOT/EncryptedMemories.xcodeproj" \
    -scheme "$SCHEME" \
    -clonedSourcePackagesDirPath "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES" \
    -packageCachePath "$ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE" \
    -packageAuthorizationProvider netrc \
    -onlyUsePackageVersionsFromResolvedFile

fi

# After a prepared build, the test run starts from the test run file of that build. That skips loading the project and
# resolving its package graph. The file holds the environment and the test bundles of the scheme.
# CI has just built it, so a missing or ambiguous file is an error: the run must not start another way.
XCTESTRUN=""
if [[ "$ACTION" == "test-without-building" && "$PREPARED" == "1" ]]; then
  XCTESTRUN_MATCHES=()
  for candidate in "$DERIVED_DATA/Build/Products/${SCHEME}_"*.xctestrun; do
    [[ -f "$candidate" ]] && XCTESTRUN_MATCHES+=("$candidate")
  done
  if [[ ${#XCTESTRUN_MATCHES[@]} -ne 1 ]]; then
    echo "[ios-tests] expected one test run file ${SCHEME}_*.xctestrun in the build products, found ${#XCTESTRUN_MATCHES[@]}." >&2
    exit 66
  fi
  XCTESTRUN="${XCTESTRUN_MATCHES[0]}"
fi

# Without this, xcodebuild boots a cold simulator on demand and the first test launches the app while the
# boot still runs; on CI that launch times out ("Failed to get background assertion"). Boot first and wait
# until the boot, data migration included, is complete.
if [[ "$ACTION" != "build-for-testing" && -n "${SIMULATOR_UDID:-}" ]]; then
  echo "[ios-tests] booting $SIMULATOR_NAME and waiting until it is ready"
  # macOS has no `timeout`; perl's alarm ends a boot that hangs after 10 minutes.
  if ! perl -e 'alarm shift; exec @ARGV' 600 xcrun simctl bootstatus "$SIMULATOR_UDID" -b; then
    echo "[ios-tests] the simulator did not finish booting within 10 minutes." >&2
    exit 1
  fi
  # A simulator that an earlier start step booted, but that this run does not test, would run next to it for the whole job.
  if [[ -n "${IOS_TEST_BOOT_RECORD:-}" && -s "$IOS_TEST_BOOT_RECORD" ]]; then
    STARTED_UDID="$(head -n 1 "$IOS_TEST_BOOT_RECORD")"
    if [[ "$STARTED_UDID" != "$SIMULATOR_UDID" ]]; then
      echo "[ios-tests] the start step booted $STARTED_UDID, but the tests use $SIMULATOR_UDID; shutting the first one down."
      xcrun simctl shutdown "$STARTED_UDID" || echo "[ios-tests] the shutdown failed; the tests go on."
    fi
  fi
fi

echo "[ios-tests] scheme: $SCHEME, destination: $DESTINATION"
if [[ -n "$XCTESTRUN" ]]; then
  echo "[ios-tests] test run file: ${XCTESTRUN##*/}"
  set -- xcrun xcodebuild \
    -xctestrun "$XCTESTRUN" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA"
else
  set -- xcrun xcodebuild \
    -project "$ROOT/EncryptedMemories.xcodeproj" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES" \
    -packageCachePath "$ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE" \
    -disableAutomaticPackageResolution \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO
fi
if [[ "$ACTION" != "build-for-testing" && "$SCHEME" == "EncryptedMemoriesMobileCI" ]]; then
  set -- "$@" "-only-testing:$TEST_TARGET"
fi
if [[ "$TEST_TARGET" == "EncryptedMemoriesMobileUITests" && -n "${IOS_TEST_PARALLEL_WORKERS:-}" ]]; then
  set -- "$@" -parallel-testing-enabled YES -parallel-testing-worker-count "$IOS_TEST_PARALLEL_WORKERS"
fi
if [[ -n "${IOS_TEST_RESULT_BUNDLE_PATH:-}" ]]; then
  set -- "$@" -resultBundlePath "$IOS_TEST_RESULT_BUNDLE_PATH"
fi
# Do not collect simulator diagnostics. In the passing hosted unit test job of queue run 38688241064, xcodebuild
# waited 600 seconds after the last test for "Failure collecting diagnostics from simulator" and got no answer.
# The collection is skipped when no test run asks for it; the trigger in a passing run is not known. The flag also
# drops the simulator sysdiagnose from the result bundle of a failed run. The test results stay.
if [[ "$ACTION" != "build-for-testing" ]]; then
  set -- "$@" -collect-test-diagnostics never
fi
TEST_STATUS=0
if [[ "$TEST_TARGET" == "EncryptedMemoriesMobileUITests" && -n "${IOS_TEST_DIAGNOSTICS_PATH:-}" ]]; then
  if [[ "${IOS_TEST_PARALLEL_WORKERS:-1}" != "1" || -z "${SIMULATOR_UDID:-}" ]]; then
    echo "[ios-tests] diagnostics require one simulator with an explicit device ID." >&2
    exit 64
  fi
  DIAGNOSTIC_SIMULATOR="$SIMULATOR_UDID"
  python3 "$ROOT/.github/scripts/collect_ui_wait_diagnostics.py" \
    --simulator "$DIAGNOSTIC_SIMULATOR" --output "$IOS_TEST_DIAGNOSTICS_PATH" -- \
    "$@" -parallel-testing-enabled NO "$ACTION" || TEST_STATUS=$?
else
  "$@" "$ACTION" || TEST_STATUS=$?
fi
[[ "$TEST_STATUS" -eq 0 ]] || exit "$TEST_STATUS"

# A test run that executed no test is a failure, however xcodebuild ended: a test run file or a selection that matches
# nothing must not pass, and neither must a run in which every test was skipped. The numbers come from the result bundle,
# so the check needs IOS_TEST_RESULT_BUNDLE_PATH (CI sets it in both test steps).
if [[ "$ACTION" != "build-for-testing" && -n "${IOS_TEST_RESULT_BUNDLE_PATH:-}" ]]; then
  EXECUTED_TESTS=""
  if RESULT_SUMMARY="$(xcrun xcresulttool get test-results summary --path "$IOS_TEST_RESULT_BUNDLE_PATH" 2>/dev/null)"; then
    EXECUTED_TESTS="$(printf '%s' "$RESULT_SUMMARY" | python3 -c '
import json, sys
summary = json.load(sys.stdin)
print(sum(int(summary.get(key, 0)) for key in ("passedTests", "failedTests", "expectedFailures")), summary["totalTestCount"])' 2>/dev/null || true)"
  fi
  if [[ ! "$EXECUTED_TESTS" =~ ^[1-9][0-9]*\ [0-9]+$ ]]; then
    echo "[ios-tests] the test run executed no test (passed, failed and expected failures: ${EXECUTED_TESTS%% *}); this is a failure." >&2
    exit 70
  fi
  echo "[ios-tests] executed tests: ${EXECUTED_TESTS%% *} (${EXECUTED_TESTS##* } in total, skipped ones included)"
fi
