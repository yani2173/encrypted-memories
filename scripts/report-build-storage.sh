#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/build-paths.sh"

warn_gib="${ENCRYPTED_MEMORIES_BUILD_WARN_GIB:-100}"
total_kib=0

# Sets size_kib and incomplete in the caller. A path that cannot be read completely gets the note "(incomplete)": GNU du
# prints the size of the readable part, BSD du prints nothing, and both exit with an error. The report goes on either way.
measure_kib() {
  local status=0
  size_kib="$(du -sk "$1" 2>/dev/null | awk '{print $1; exit}')" || status=$?
  incomplete=""
  [[ "$status" -eq 0 ]] || incomplete=" (incomplete)"
  return 0
}

report_path() {
  local path="$1"
  local size_kib incomplete
  [[ -e "$path" ]] || return 0
  measure_kib "$path"
  if [[ -z "$size_kib" ]]; then
    [[ -z "$incomplete" ]] || printf '%8s GiB  %s%s\n' "?" "$path" "$incomplete"
    return 0
  fi
  total_kib=$((total_kib + size_kib))
  printf '%8.1f GiB  %s%s\n' "$(awk -v kib="$size_kib" 'BEGIN { print kib / 1048576 }')" "$path" "$incomplete"
}

# The size of each folder directly inside a folder, for the report only: it is not added to the total.
report_children() {
  local path="${1%/}"
  local child size_kib incomplete
  [[ -d "$path" ]] || return 0
  while IFS= read -r -d '' child; do
    measure_kib "$child"
    if [[ -n "$size_kib" ]]; then
      printf '%8.2f GiB    %s%s\n' "$(awk -v kib="$size_kib" 'BEGIN { print kib / 1048576 }')" "${child#"$path"/}" "$incomplete"
    else
      printf '%8s GiB    %s%s\n' "?" "${child#"$path"/}" "$incomplete"
    fi
  done < <(find "$path" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
}

echo "Canonical Encrypted Memories build storage:"
report_path "$ENCRYPTED_MEMORIES_BUILD_ROOT"
report_children "$ENCRYPTED_MEMORIES_BUILD_ROOT"
report_path "$ROOT/Packages/EncryptedMemoriesKit/.build"
report_path "$ROOT/Vendor/sdk-swift/.build"

echo "Ad-hoc Proton build roots outside the canonical location:"
while IFS= read -r path; do
  report_path "$path"
done < <(find /private/tmp -xdev -mindepth 1 -maxdepth 1 -type d \
  \( -iname '*proton*spm*' -o -iname '*proton*derived*' -o -iname '*proton*dd.noindex' \
     -o -iname '*proton*tests*' -o -iname '*proton*gates*' \) -print 2>/dev/null | sort)

total_gib="$(awk -v kib="$total_kib" 'BEGIN { printf "%.1f", kib / 1048576 }')"
echo "Total reported build storage: $total_gib GiB"

if (( total_kib > warn_gib * 1048576 )); then
  echo "WARNING: Encrypted Memories build storage exceeds ${warn_gib} GiB." >&2
fi
