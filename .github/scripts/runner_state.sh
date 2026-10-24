#!/bin/bash
# Print the state of the runner: load, memory, disk, simulators, crash reports and the busiest processes.
# Counts and process names only: no path, host name or account name. It never fails, whatever is missing.
# Usage: runner_state.sh <label>

label="${1:-state}"

section() {
  printf '%s\n' "$1"
}

run() {
  "$@" 2>/dev/null || true
}

crash_names() {
  sed -E 's#.*/##; s/-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}(-[0-9]+)?[.]ips$//' | sort | uniq -c | sort -rn | head -5
}

# simctl can hang on a runner in a bad state; each call is limited, like the boot wait of the test script.
simctl_seconds="${RUNNER_STATE_SIMCTL_SECONDS:-20}"
booted_simulators() {
  run perl -e 'alarm shift; exec @ARGV' "$simctl_seconds" xcrun simctl list devices booted
}

# A glob instead of a search: a runner or a workstation can hold many gigabytes of simulator data.
simulator_crash_files() {
  shopt -s nullglob
  local file
  local devices="${HOME:-/nonexistent}/Library/Developer/CoreSimulator/Devices"
  for file in "$devices"/*/data/Library/Logs/CrashReporter/*.ips; do
    printf '%s\n' "$file"
  done
}

report() {
  section "== runner state ($label) =="
  section "load average: $(run sysctl -n vm.loadavg)"
  section "cpus: $(run sysctl -n hw.ncpu)"
  section "memory: $(run sysctl -n hw.memsize | awk '{printf "%.1f GiB", $1 / 1073741824}')"
  section "swap: $(run sysctl -n vm.swapusage)"
  run vm_stat | head -4
  section "disk: $(run df -k / | awk 'NR == 2 {printf "%.1f GiB free of %.1f GiB", $4 / 1048576, $2 / 1048576}')"
  section "booted simulators: $(booted_simulators | grep -c Booted)"
  host_reports="$(run find "${HOME:-/nonexistent}/Library/Logs/DiagnosticReports" -maxdepth 1 -name '*.ips' -type f)"
  simulator_reports="$(simulator_crash_files)"
  section "crash reports on the host: $(printf '%s' "$host_reports" | grep -c .)"
  printf '%s\n' "$host_reports" | grep . | crash_names
  section "crash reports in the simulators: $(printf '%s' "$simulator_reports" | grep -c .)"
  printf '%s\n' "$simulator_reports" | grep . | crash_names
  section "busiest processes (cpu percent, name):"
  run ps -Ao pcpu=,comm= | sort -rn | head -5 |
    awk '{p = $1; $1 = ""; sub(/^ +/, ""); n = split($0, a, "/"); print p, a[n]}'
}

output="$(report 2>/dev/null)"
printf '%s\n' "$output"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '```\n%s\n```\n\n' "$output"
  } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null
fi
exit 0
