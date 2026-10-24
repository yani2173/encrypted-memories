#!/usr/bin/env bash
# Tests of run_ui_tests_with_retry.sh and runner_state.sh with a fake test command and a fake xcrun.
#
# Matched strings, as defined in the wrapper:
#   bootstrap failure: a line that starts with "<Name>-Runner (<pid>) encountered an error (Early unexpected exit,
#                      operation never finished bootstrapping" or
#                      "...(The test runner crashed while preparing to run tests"
#   test case started: the text "Test Case '<name>' started" anywhere in the output of attempt 1
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wrapper="$here/run_ui_tests_with_retry.sh"
state="$here/runner_state.sh"
work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
failures=0
# The hygiene job runs this test inside a step that has a real step summary and step output. No call of the test
# may write there, so every call inherits files of the test, and the real files are compared at the end.
real_summary="${GITHUB_STEP_SUMMARY:-}"
real_output="${GITHUB_OUTPUT:-}"
file_size() { if [[ -n "$1" && -f "$1" ]]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }
real_summary_size="$(file_size "$real_summary")"
real_output_size="$(file_size "$real_output")"
export GITHUB_STEP_SUMMARY="$work/step-summary" GITHUB_OUTPUT="$work/step-output"
: > "$GITHUB_STEP_SUMMARY"; : > "$GITHUB_OUTPUT"
uuid='0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9'
other_uuid='1B2C3D4E-5F60-7182-93A4-B5C6D7E8F900'

fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
expect() { # description expected actual
  if [[ "$2" != "$3" ]]; then fail "$1: expected [$2], got [$3]"; fi
}
contains() { # description file text
  grep -q -F -- "$3" "$2" || fail "$1: [$3] missing in $2"
}
lacks() { # description file text
  if grep -q -F -- "$3" "$2"; then fail "$1: [$3] found in $2"; fi
}

bootstrap_line=$'\tEncryptedMemoriesMobileUITests-Runner (69288) encountered an error (Early unexpected exit, '
bootstrap_line+='operation never finished bootstrapping - no restart will be attempted. '
bootstrap_line+='(Underlying Error: The test runner crashed while preparing to run tests: Runner at handleStalledWait))'

# A scenario: a directory with a fake xcrun, a fake test command that plays one script per attempt, and the CI files.
new_case() {
  case_dir="$work/$1"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/bin" "$case_dir/temp"
  : > "$case_dir/calls"
  : > "$case_dir/xcrun-calls"
  cat > "$case_dir/bin/xcrun" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$case_dir/xcrun-calls"
# A hanging simctl: exec, so the alarm of the caller ends the sleep itself.
[[ -z "\${FAKE_XCRUN_HANG:-}" ]] || exec sleep 30
if [[ "\$*" == *"list devices booted"* ]]; then
  echo "    Zz Test Phone (11111111-2222-3333-4444-555555555555) (Booted)"
fi
exit \${FAKE_XCRUN_STATUS:-0}
EOF
  cat > "$case_dir/fake-tests" <<EOF
#!/usr/bin/env bash
# Play the script of this attempt: "<exit status>|<output>" with \n for new lines; keep the bundle like xcodebuild.
n=\$(( \$(wc -l < "$case_dir/calls") + 1 ))
echo "attempt \$n" >> "$case_dir/calls"
if [[ "\$n" == 2 ]]; then cp "\${GITHUB_OUTPUT:-/dev/null}" "$case_dir/output-at-attempt-2"; fi
if [[ -e "\$IOS_TEST_RESULT_BUNDLE_PATH" ]]; then echo "bundle exists at attempt \$n" >> "$case_dir/calls"; exit 99; fi
mkdir -p "\$IOS_TEST_RESULT_BUNDLE_PATH"
line="\$(sed -n "\${n}p" "$case_dir/script")"
printf '%b\n' "\${line#*|}"
exit "\${line%%|*}"
EOF
  chmod +x "$case_dir/bin/xcrun" "$case_dir/fake-tests"
  : > "$case_dir/summary"
  : > "$case_dir/output"
}

run_case() { # extra environment assignments are passed as arguments
  env PATH="$case_dir/bin:$PATH" RUNNER_TEMP="$case_dir/temp" GITHUB_STEP_SUMMARY="$case_dir/summary" \
    GITHUB_OUTPUT="$case_dir/output" IOS_TEST_RESULT_BUNDLE_PATH="$case_dir/temp/ios-ui.xcresult" "$@" \
    bash "$wrapper" "$case_dir/fake-tests" > "$case_dir/stdout" 2>&1
  status=$?
}
attempts() { wc -l < "$case_dir/calls" | tr -d ' '; }
destination="[ios-tests] scheme: EncryptedMemoriesMobileCI, destination: platform=iOS Simulator,id=$uuid"

# 1. A pass needs no retry.
new_case pass
printf '0|%s\n' "all tests passed" > "$case_dir/script"
run_case
expect 'pass: exit' 0 "$status"; expect 'pass: attempts' 1 "$(attempts)"
lacks 'pass: no warning' "$case_dir/stdout" '::warning'; expect 'pass: no output flag' '' "$(cat "$case_dir/output")"

# 1b. Without a command the wrapper refuses to run.
new_case no_command
env PATH="$case_dir/bin:$PATH" RUNNER_TEMP="$case_dir/temp" bash "$wrapper" > "$case_dir/stdout" 2>&1
expect 'no command: exit' 64 "$?"
contains 'no command: usage message' "$case_dir/stdout" 'Usage:'

# 2. The runner bootstrap failure before any test case: one retry, the first bundle and log are kept.
new_case bootstrap
{
  printf '65|%s\\n%s\n' "$destination" "$bootstrap_line"
  printf '0|%s\n' 'second attempt passes'
} > "$case_dir/script"
run_case
expect 'bootstrap: exit' 0 "$status"; expect 'bootstrap: attempts' 2 "$(attempts)"
lacks 'bootstrap: bundle moved before attempt 2' "$case_dir/calls" 'bundle exists'
[[ -d "$case_dir/temp/ios-ui-attempt1.xcresult" ]] || fail 'bootstrap: the bundle of attempt 1 is kept'
[[ -f "$case_dir/temp/ios-ui-attempt1.log" && -f "$case_dir/temp/ios-ui-attempt2.log" ]] \
  || fail 'bootstrap: both logs are kept'
contains 'bootstrap: warning annotation' "$case_dir/stdout" '::warning title=iOS UI tests were retried::'
contains 'bootstrap: summary of the retry' "$case_dir/summary" \
  'attempt 1 ended with the XCTest runner bootstrap failure'
contains 'bootstrap: summary of the result' "$case_dir/summary" 'attempt 2 passed after the retry'
contains 'bootstrap: step output' "$case_dir/output" 'retried=true'
contains 'bootstrap: step output exists before attempt 2 starts' "$case_dir/output-at-attempt-2" 'retried=true'
expect 'bootstrap: only the simulator of the log is shut down' "simctl shutdown $uuid" "$(cat "$case_dir/xcrun-calls")"

# 3. The same signature after a test case started is not retried.
new_case started
printf '65|%s\\n%s\\n%s\n' "$destination" "Test Case '-[Suite testOne]' started." "$bootstrap_line" > "$case_dir/script"
run_case
expect 'started: exit' 65 "$status"; expect 'started: attempts' 1 "$(attempts)"
lacks 'started: no warning' "$case_dir/stdout" '::warning'

# 4. Other failures are not retried and keep their exit code: a failed test, a timeout, a snapshot stall.
for failure in "Test Case '-[Suite testTwo]' failed (30.1 seconds)." \
    'Timed out after 600.0 seconds while waiting' 'UI snapshot stalled' ''; do
  new_case other
  printf '65|%s\n' "$failure" > "$case_dir/script"
  run_case
  expect "other [$failure]: exit" 65 "$status"; expect "other [$failure]: attempts" 1 "$(attempts)"
done

# 5. A failing second attempt gives the second exit code and keeps everything.
new_case twice
{ printf '65|%s\\n%s\n' "$destination" "$bootstrap_line"; printf '66|%s\n' "$bootstrap_line"; } > "$case_dir/script"
run_case
expect 'twice: exit of the last attempt' 66 "$status"; expect 'twice: attempts (one retry by default)' 2 "$(attempts)"
contains 'twice: summary of the failure' "$case_dir/summary" 'attempt 2 failed with exit code 66 after the retry'
[[ -d "$case_dir/temp/ios-ui-attempt1.xcresult" && -d "$case_dir/temp/ios-ui.xcresult" ]] \
  || fail 'twice: both bundles are kept'

# 6. Text that a test prints inside a line does not count as the runner error.
new_case spoof
printf '65|%s\n' "log: (Early unexpected exit, operation never finished bootstrapping) is text" > "$case_dir/script"
run_case
expect 'spoof: exit' 65 "$status"; expect 'spoof: attempts' 1 "$(attempts)"
new_case spoof_indent
printf '65|%s\n' \
  "prefix Suite-Runner (1) encountered an error (Early unexpected exit, operation never finished bootstrapping" \
  > "$case_dir/script"
run_case
expect 'spoof inside a line: attempts' 1 "$(attempts)"
new_case crashed_runner
{
  printf '65|%s\n' "Suite-Runner (7) encountered an error (The test runner crashed while preparing to run tests: x)"
  printf '0|ok\n'
} > "$case_dir/script"
run_case
expect 'second runner error text: exit' 0 "$status"; expect 'second runner error text: attempts' 2 "$(attempts)"
new_case other_runner_error
printf '65|%s\n' "Suite-Runner (7) encountered an error (Failed to launch the application)" > "$case_dir/script"
run_case
expect 'other runner error: attempts' 1 "$(attempts)"
new_case runner_error_text_later_in_the_line
late_text="Suite-Runner (7) encountered an error (Failed to launch. "
late_text+="(Underlying Error: The test runner crashed while preparing to run tests))"
printf '65|%s\n' "$late_text" > "$case_dir/script"
run_case
expect 'bootstrap text later in the line: attempts' 1 "$(attempts)"
new_case passed_with_the_line
printf '0|%s\n' "$bootstrap_line" > "$case_dir/script"
run_case
expect 'a passing attempt is never repeated: exit' 0 "$status"
expect 'a passing attempt is never repeated: attempts' 1 "$(attempts)"

# 7. A missing or invalid simulator id skips the shutdown and still retries; a failing shutdown still retries.
dashes="$(printf -- '-%.0s' {1..36})"
for destination_line in '' '[ios-tests] scheme: X, destination: platform=iOS Simulator,id=not-a-uuid' \
    "[ios-tests] scheme: X, destination: platform=iOS Simulator,id=$dashes" \
    "[ios-tests] scheme: X, destination: platform=iOS Simulator,id=\$(touch $work/injected)"; do
  new_case no_id
  { printf '65|%s\\n%s\n' "$destination_line" "$bootstrap_line"; printf '0|ok\n'; } > "$case_dir/script"
  run_case
  expect "no id [$destination_line]: exit" 0 "$status"; expect "no id [$destination_line]: attempts" 2 "$(attempts)"
  expect "no id [$destination_line]: no shutdown" '' "$(cat "$case_dir/xcrun-calls")"
  [[ ! -e "$work/injected" ]] || fail 'the log text reached a shell'
done
new_case two_destinations
{
  printf '65|%s\\n%s\\n%s\n' "$destination" \
    "[ios-tests] scheme: X, destination: platform=iOS Simulator,id=$other_uuid" "$bootstrap_line"
  printf '0|ok\n'
} > "$case_dir/script"
run_case
expect 'two destination lines: exit' 0 "$status"; expect 'two destination lines: attempts' 2 "$(attempts)"
expect 'two destination lines: the first one wins' "simctl shutdown $uuid" "$(cat "$case_dir/xcrun-calls")"
new_case shutdown_hangs
{ printf '65|%s\\n%s\n' "$destination" "$bootstrap_line"; printf '0|ok\n'; } > "$case_dir/script"
started_at=$SECONDS
run_case FAKE_XCRUN_HANG=1 UI_TEST_SIMCTL_SECONDS=1
expect 'hanging shutdown: exit' 0 "$status"; expect 'hanging shutdown: attempts' 2 "$(attempts)"
(( SECONDS - started_at < 20 )) || fail 'hanging shutdown: the wrapper waited for simctl'
new_case bundle_stays
printf '#!/usr/bin/env bash\nexit 1\n' > "$case_dir/bin/mv"; chmod +x "$case_dir/bin/mv"
{ printf '65|%s\n' "$bootstrap_line"; printf '0|ok\n'; } > "$case_dir/script"
run_case
expect 'bundle that cannot be kept: exit' 0 "$status"; expect 'bundle that cannot be kept: attempts' 2 "$(attempts)"
contains 'bundle that cannot be kept: said so' "$case_dir/stdout" 'could not be kept; it was removed'
lacks 'bundle that cannot be kept: no false claim' "$case_dir/stdout" 'result bundle and log are kept'
new_case shutdown_fails
{ printf '65|%s\\n%s\n' "$destination" "$bootstrap_line"; printf '0|ok\n'; } > "$case_dir/script"
run_case FAKE_XCRUN_STATUS=1
expect 'failing shutdown: exit' 0 "$status"; expect 'failing shutdown: attempts' 2 "$(attempts)"

# 8. The retry count is a variable: none, the default one, and more.
new_case bad_retry_count
printf '65|%s\n' "$bootstrap_line" > "$case_dir/script"
for count in x -1 '' 1.5 '1+1' 08 010; do
  run_case UI_TEST_MAX_RETRIES="$count"
  if [[ -z "$count" ]]; then
    expect 'empty retry count: default of one retry' 2 "$(attempts)"
  else
    expect "retry count [$count]: refused" 64 "$status"; expect "retry count [$count]: nothing ran" 0 "$(attempts)"
  fi
  : > "$case_dir/calls"; rm -rf "$case_dir/temp/ios-ui.xcresult" "$case_dir/temp/ios-ui-attempt1.xcresult"
done
new_case no_retries
printf '65|%s\n' "$bootstrap_line" > "$case_dir/script"
run_case UI_TEST_MAX_RETRIES=0
expect 'no retries: exit' 65 "$status"; expect 'no retries: attempts' 1 "$(attempts)"
new_case three_attempts
{ printf '65|%s\n' "$bootstrap_line"; printf '65|%s\n' "$bootstrap_line"; printf '0|ok\n'; } > "$case_dir/script"
run_case UI_TEST_MAX_RETRIES=2
expect 'two retries: exit' 0 "$status"; expect 'two retries: attempts' 3 "$(attempts)"

# 9. Without a result bundle path the wrapper still works.
new_case no_bundle
{ printf '65|%s\n' "$bootstrap_line"; printf '0|ok\n'; } > "$case_dir/script"
sed -i.bak -e 's#^if \[\[ -e "\$IOS_TEST_RESULT_BUNDLE_PATH" \]\].*##' \
  -e 's#^mkdir -p "\$IOS_TEST_RESULT_BUNDLE_PATH"##' "$case_dir/fake-tests" && rm "$case_dir/fake-tests.bak"
env PATH="$case_dir/bin:$PATH" RUNNER_TEMP="$case_dir/temp" bash "$wrapper" "$case_dir/fake-tests" \
  > "$case_dir/stdout" 2>&1
expect 'no bundle path: exit' 0 "$?"; expect 'no bundle path: attempts' 2 "$(attempts)"

# 10. The runner state never fails and never prints a user path, host name or account name.
host_names=("$(hostname 2>/dev/null)" "$(hostname -s 2>/dev/null)" "$(scutil --get ComputerName 2>/dev/null)")
fake_account="zz-state-account"
fake_home="/Us""ers/$fake_account"
state_output="$(HOME="$fake_home" bash "$state" start)"; state_status=$?
expect 'state: exit' 0 "$state_status"
printf '%s\n' "$state_output" > "$work/state-output"
contains 'state: label' "$work/state-output" '== runner state (start) =='
lacks 'state: no /Users/ path' "$work/state-output" '/Users/'
lacks 'state: no /home/ path' "$work/state-output" '/home/'
lacks 'state: no account name of the home folder' "$work/state-output" "$fake_account"
for name in "${host_names[@]}" "$(id -un)" "${HOME##*/}"; do
  # "runner" is the public account name of hosted runners.
  if [[ -n "$name" && ${#name} -gt 2 && "$name" != runner ]]; then
    lacks "state: no name [$name]" "$work/state-output" "$name"
  fi
done
# Crash reports are counted by name, on the host and in a simulator, in a home folder without any other content.
crash_home="$work/crash-home"
simulator_reports="$crash_home/Library/Developer/CoreSimulator/Devices/$uuid/data/Library/Logs/CrashReporter"
mkdir -p "$crash_home/Library/Logs/DiagnosticReports" "$simulator_reports"
: > "$crash_home/Library/Logs/DiagnosticReports/Suite-Runner-2026-10-14-120000.ips"
: > "$simulator_reports/SpringBoard-2026-10-14-120001.ips"
crash_output="$(HOME="$crash_home" bash "$state" crash)"
printf '%s\n' "$crash_output" > "$work/crash-output"
contains 'state: host crash report counted' "$work/crash-output" 'crash reports on the host: 1'
contains 'state: simulator crash report counted' "$work/crash-output" 'crash reports in the simulators: 1'
contains 'state: host crash report named' "$work/crash-output" 'Suite-Runner'
contains 'state: simulator crash report named' "$work/crash-output" 'SpringBoard'
lacks 'state: no path of the crash report' "$work/crash-output" "$crash_home"
# The report counts the booted simulators and does not name them.
new_case state_names
names_output="$(env PATH="$case_dir/bin:$PATH" bash "$state" names)"
printf '%s\n' "$names_output" | grep -q 'booted simulators: 1' || fail 'state: one booted simulator counted'
printf '%s\n' "$names_output" | grep -q 'Test Phone' && fail 'state: a simulator name was printed'
# A hanging simctl does not hold the report.
new_case state_hang
started_at=$SECONDS
hang_output="$(env PATH="$case_dir/bin:$PATH" FAKE_XCRUN_HANG=1 RUNNER_STATE_SIMCTL_SECONDS=1 \
  bash "$state" hang)"
hang_status=$?
expect 'state with a hanging simctl: exit' 0 "$hang_status"
(( SECONDS - started_at < 20 )) || fail 'state with a hanging simctl: the report waited for simctl'
printf '%s\n' "$hang_output" | grep -q 'booted simulators: 0' || fail 'state with a hanging simctl: no simulator count'
bare="$(env PATH=/nonexistent /bin/bash "$state" empty)"; bare_status=$?
expect 'state without any tool: exit' 0 "$bare_status"
printf '%s\n' "$bare" | grep -q '== runner state (empty) ==' || fail 'state without any tool: label'
summary_file="$work/state-summary"; : > "$summary_file"
GITHUB_STEP_SUMMARY="$summary_file" bash "$state" end > /dev/null
contains 'state: summary' "$summary_file" '== runner state (end) =='
GITHUB_STEP_SUMMARY=/nonexistent/summary bash "$state" end > /dev/null 2>&1
expect 'state with an unwritable summary: exit' 0 "$?"

expect 'the real step summary was not written' "$real_summary_size" "$(file_size "$real_summary")"
expect 'the real step output was not written' "$real_output_size" "$(file_size "$real_output")"

if [[ $failures -gt 0 ]]; then echo "$failures check(s) failed" >&2; exit 1; fi
echo "run_ui_tests_with_retry tests passed"
