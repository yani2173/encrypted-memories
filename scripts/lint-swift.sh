#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
source "$ROOT/scripts/build-paths.sh"

usage() {
  echo "usage: scripts/lint-swift.sh --all | --diff BASE HEAD | FILE..." >&2
}

declare -a files=()
case "${1:-}" in
  --all)
    shift
    while IFS= read -r file; do files+=("$file"); done < <(
      git ls-files --cached --others --exclude-standard -- '*.swift'
    )
    ;;
  --diff)
    [[ $# -eq 3 ]] || { usage; exit 64; }
    base="$2"
    head="$3"
    shift 3
    while IFS= read -r file; do files+=("$file"); done < <(
      git diff --diff-filter=ACMR --name-only "$base...$head" -- '*.swift'
    )
    ;;
  "")
    usage
    exit 64
    ;;
  *)
    files=("$@")
    ;;
esac

declare -a source_files=()
if (( ${#files[@]} > 0 )); then
  for file in "${files[@]}"; do
    case "$file" in
      Vendor/*|EncryptedMemories.xcodeproj/*) continue ;;
    esac
    [[ -f "$file" ]] && source_files+=("$file")
  done
fi

if [[ ${#source_files[@]} -eq 0 ]]; then
  echo "No changed Swift files require linting."
  exit 0
fi

swiftlint="${SWIFTLINT_EXECUTABLE:-}"
if [[ -z "$swiftlint" ]] && command -v swiftlint >/dev/null 2>&1; then
  swiftlint="$(command -v swiftlint)"
fi
if [[ -z "$swiftlint" ]]; then
  for candidate in \
    "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES/artifacts/swiftlintplugins/SwiftLintBinary/SwiftLintBinary.artifactbundle/macos/swiftlint" \
    "$ENCRYPTED_MEMORIES_BUILD_ROOT/SourcePackages/artifacts/swiftlintplugins/SwiftLintBinary/SwiftLintBinary.artifactbundle/macos/swiftlint"; do
    if [[ -x "$candidate" ]]; then
      swiftlint="$candidate"
      break
    fi
  done
fi
[[ -x "$swiftlint" ]] || {
  echo "SwiftLint 0.65.1 is required. Set SWIFTLINT_EXECUTABLE to its executable path." >&2
  exit 69
}

actual_swiftlint_version="$($swiftlint version)"
[[ "$actual_swiftlint_version" == "0.65.1" ]] || {
  echo "SwiftLint 0.65.1 is required; found $actual_swiftlint_version." >&2
  exit 69
}

status=0
output="$("$swiftlint" lint --strict --config "$ROOT/.swiftlint.yml" "${source_files[@]}" 2>&1)" || status=$?
printf '%s\n' "$output"
[[ $status -eq 0 ]] || exit "$status"
# Without SourceKit, or when SourceKit fails, SwiftLint skips the comment rules and still succeeds. That would be a
# check that does not run.
if grep -qE "Skipping enabled rule|SourceKit-based rules will be skipped" <<< "$output"; then
  echo "A SwiftLint rule was skipped, so the style check is incomplete." >&2
  exit 1
fi
