#!/usr/bin/env bash
# The style check of CI: SwiftLint on the changed files (all files without a base commit) and swift-format on all files.
# BASE_SHA and HEAD_SHA name the commits of the change. SWIFTLINT_EXECUTABLE and SWIFT_FORMAT_EXECUTABLE select the
# tools; without them the macOS toolchain is used.
set -euo pipefail

cd "$(dirname "$0")/.."

# SwiftLint can skip its comment rules without a message that this script knows. Before the real run, a file with a
# comment that the rules forbid must fail the check; if it passes, the check does not run completely.
canary_directory="$(mktemp -d)"
trap 'rm -rf "$canary_directory"' EXIT
printf '// canary \xe2\x80\x94 canary\nlet canary = 1\n' > "$canary_directory/StyleCanary.swift"
if bash scripts/lint-swift.sh "$canary_directory/StyleCanary.swift" > /dev/null 2>&1; then
  echo "SwiftLint did not report the forbidden comment of the canary file; the style check does not run completely." >&2
  exit 1
fi

if [[ -n "${BASE_SHA:-}" ]] && git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
  bash scripts/lint-swift.sh --diff "$BASE_SHA" "${HEAD_SHA:?HEAD_SHA is required with BASE_SHA}"
else
  bash scripts/lint-swift.sh --all
fi
bash scripts/check-swift-format.sh --all
