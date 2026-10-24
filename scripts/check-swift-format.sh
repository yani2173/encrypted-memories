#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

usage() {
  echo "usage: scripts/check-swift-format.sh --all | --diff BASE HEAD | FILE..." >&2
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
for file in "${files[@]}"; do
  case "$file" in
    Vendor/*|EncryptedMemories.xcodeproj/*) continue ;;
  esac
  [[ -f "$file" ]] && source_files+=("$file")
done

if [[ ${#source_files[@]} -eq 0 ]]; then
  echo "No Swift files require a format check."
  exit 0
fi

# CI on Linux passes its own swift-format; everywhere else the tool of the selected Xcode runs.
if [[ -n "${SWIFT_FORMAT_EXECUTABLE:-}" ]]; then
  swift_format=("$SWIFT_FORMAT_EXECUTABLE")
else
  swift_format=(xcrun swift-format)
fi

"${swift_format[@]}" lint \
  --strict \
  --parallel \
  --configuration "$ROOT/.swift-format" \
  "${source_files[@]}"
