#!/usr/bin/env bash
# Run the iOS UI tests, and run them once more when the XCTest runner failed to bootstrap before any test case started.
# Usage: run_ui_tests_with_retry.sh <command> [arguments...]
# A failed test, a wait that ran out of time and any other failure are never retried.
set -uo pipefail

# How often the command may be repeated. A later change of the policy is this line.
max_retries="${UI_TEST_MAX_RETRIES:-1}"
if [[ ! "$max_retries" =~ ^(0|[1-9][0-9]*)$ ]]; then
  echo "UI_TEST_MAX_RETRIES must be a whole number." >&2
  exit 64
fi
if [[ $# -eq 0 ]]; then
  echo "Usage: run_ui_tests_with_retry.sh <command> [arguments...]" >&2
  exit 64
fi
# simctl can hang on a runner in the state that caused the failure; the shutdown never holds the job for longer.
shutdown_seconds="${UI_TEST_SIMCTL_SECONDS:-60}"
bundle="${IOS_TEST_RESULT_BUNDLE_PATH:-}"
logs="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"

# The matched strings. The first is the runner error line of xcodebuild and is anchored at the start of the line, so
# text that a test prints inside a line cannot match it. The second is the XCTest line that announces a test case;
# it is matched anywhere, because a false match only prevents a retry.
runner_error='^[[:space:]]*[A-Za-z0-9_.-]+-Runner \([0-9]+\) encountered an error \('
bootstrap_texts='(Early unexpected exit, operation never finished bootstrapping'
bootstrap_texts+='|The test runner crashed while preparing to run tests)'
runner_failed_to_bootstrap() {
  local log="$1"
  grep -q -E "${runner_error}${bootstrap_texts}" "$log" || return 1
  if grep -q -E "Test Case '.*' started" "$log"; then
    return 1
  fi
  return 0
}

# The simulator that attempt 1 used: the destination line of the test script. No valid id means no shutdown.
simulator_id() {
  sed -n -E 's/.*destination: platform=iOS Simulator,id=([0-9A-Fa-f-]{36}).*/\1/p' "$1" | head -1
}

summary() {
  printf '%s\n' "$1"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

attempt=1
retried=false
while true; do
  log="$logs/ios-ui-attempt$attempt.log"
  "$@" 2>&1 | tee "$log"
  status=${PIPESTATUS[0]}
  if [[ $status -eq 0 ]] || (( attempt > max_retries )) || ! runner_failed_to_bootstrap "$log"; then
    break
  fi
  retried=true
  # Written before the next attempt starts: a timeout or a cancel during that attempt still uploads the first one.
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'retried=true\n' >> "$GITHUB_OUTPUT"
  fi
  reason="the XCTest runner bootstrap failure before any test case started"
  kept="Its log is kept."
  if [[ -n "$bundle" && -e "$bundle" ]]; then
    if mv "$bundle" "${bundle%.xcresult}-attempt$attempt.xcresult"; then
      kept="Its result bundle and log are kept."
    else
      # A leftover bundle would make xcodebuild fail the next attempt at once.
      if rm -rf "$bundle"; then
        echo "The result bundle of attempt $attempt could not be kept; it was removed."
      else
        echo "The result bundle of attempt $attempt could neither be kept nor be removed."
      fi
    fi
  fi
  summary "UI tests: attempt $attempt ended with $reason; retrying once more."
  echo "::warning title=iOS UI tests were retried::Attempt $attempt ended with $reason. $kept"
  id="$(simulator_id "$log")"
  if [[ "$id" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]]; then
    perl -e 'alarm shift; exec @ARGV' "$shutdown_seconds" xcrun simctl shutdown "$id" >/dev/null 2>&1 \
      || echo "The simulator could not be shut down; the retry starts anyway."
  else
    echo "The log names no valid simulator id; the simulator stays as it is."
  fi
  attempt=$((attempt + 1))
done

if [[ "$retried" == true ]]; then
  if [[ $status -eq 0 ]]; then
    summary "UI tests: attempt $attempt passed after the retry."
  else
    summary "UI tests: attempt $attempt failed with exit code $status after the retry."
  fi
fi
exit "$status"
