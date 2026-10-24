#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

violations=0

is_public_markdown() {
  case "$1" in
    README.md | AGENTS.md | SECURITY.md | CONTRIBUTING.md | .github/pull_request_template.md | \
      Wiki/*.md | Tools/MLModels/README.md | Tools/MLModels/SigLIP2/README.md | \
      Tools/upgrade-fixtures/README.md)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

check_path() {
  local path="$1"

  case "$path" in
    *.aac | *.aiff | *.flac | *.m4a | *.mp3 | *.wav | *.mp4 | *.mov | *.m4v | \
      *.p8 | *.p12 | *.cer | *.mobileprovision | *.provisionprofile | *.ipa | *.xcarchive/* | \
      Marketing/Audio/* | Marketing/Captures/* | Marketing/Review/* | \
      EncryptedMemories.xcodeproj/* | */__pycache__/* | *.pyc | *.pyo | *.pyd | fastlane/* | \
      scripts/archive-app-store.sh | THIRD_PARTY_NOTICES | APPLE_RELEASE_SETUP.rst)
      echo "Forbidden public path: $path" >&2
      violations=1
      return
      ;;
    *.md)
      if ! is_public_markdown "$path"; then
        echo "Private Markdown path: $path" >&2
        violations=1
      fi
      ;;
  esac
}

while IFS= read -r -d '' path; do
  check_path "$path"
done < <(git ls-files -z)

while IFS= read -r -d '' entry; do
  mode="${entry%% *}"
  path="${entry#* }"
  if [[ "$mode" == 100755 ]]; then
    if [[ ! -f "$path" || "$(head -c 2 -- "$path")" != '#!' ]]; then
      echo "Unexpected executable mode: $path" >&2
      violations=1
    fi
  elif [[ "$mode" == 100644 ]]; then
    if [[ -f "$path" && "$(head -c 2 -- "$path")" == '#!' ]]; then
      echo "Script is not executable: $path" >&2
      violations=1
    fi
  else
    echo "Unexpected public file mode $mode: $path" >&2
    violations=1
  fi
done < <(git ls-files -z --format='%(objectmode) %(path)')

if (( violations != 0 )); then
  exit 1
fi

echo "Public tree boundary passed."
