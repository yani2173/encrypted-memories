#!/bin/zsh
set -euo pipefail

if [[ $# -lt 5 || $# -gt 7 ]]; then
  echo "Usage: rollback-ml-model-release.sh SOURCE_PAIR NEW_SEQUENCE PRIVATE_KEY REPOSITORY_REVISION RELEASED_AT [RCLONE_REMOTE] [BUCKET]" >&2
  exit 64
fi

source_pair=$1
new_sequence=$2
private_key=$3
repository_revision=$4
released_at=$5
remote_name=${6:-r2}
bucket=${7:-encrypted-memories-models}
public_key_base64='qXMyoYhp7TbPPXPAyEKDoy+kkl8He7I5RNXWgjNc5Kk='

[[ ${#source_pair} == 64 && "$source_pair" != *[^0-9a-f]* ]] || {
  echo "SOURCE_PAIR must be 64 lowercase hexadecimal characters" >&2
  exit 64
}
[[ "$new_sequence" == <1-> ]] || { echo "NEW_SEQUENCE must be a positive integer" >&2; exit 64; }
[[ -f "$private_key" ]] || { echo "PRIVATE_KEY does not exist" >&2; exit 66; }
command -v rclone >/dev/null || { echo "rclone is required" >&2; exit 69; }
command -v python3 >/dev/null || { echo "python3 is required for signed R2 requests" >&2; exit 69; }
[[ -n "${R2_ENDPOINT:-}" ]] || { echo "R2_ENDPOINT is required" >&2; exit 64; }
[[ -n "${R2_ACCESS_KEY_ID:-}" ]] || { echo "R2_ACCESS_KEY_ID is required" >&2; exit 64; }
[[ -n "${R2_SECRET_ACCESS_KEY:-}" ]] || { echo "R2_SECRET_ACCESS_KEY is required" >&2; exit 64; }
[[ "${RCLONE_CONFIG_R2_ENDPOINT:-}" == "$R2_ENDPOINT" ]] || {
  echo "The rclone endpoint must match R2_ENDPOINT" >&2
  exit 64
}
[[ "${RCLONE_CONFIG_R2_ACCESS_KEY_ID:-}" == "$R2_ACCESS_KEY_ID" ]] || {
  echo "The rclone access key must match the signed-request configuration" >&2
  exit 64
}
[[ "${RCLONE_CONFIG_R2_SECRET_ACCESS_KEY:-}" == "$R2_SECRET_ACCESS_KEY" ]] || {
  echo "The rclone secret key must match the signed-request configuration" >&2
  exit 64
}
python3 -c '
import sys
from urllib.parse import urlsplit

endpoint = urlsplit(sys.argv[1].rstrip("/"))
if (
    endpoint.scheme != "https"
    or not endpoint.hostname
    or endpoint.username
    or endpoint.password
    or endpoint.query
    or endpoint.fragment
):
    raise SystemExit("R2_ENDPOINT must be an HTTPS URL")
' "$R2_ENDPOINT"

script_dir=${0:A:h}
rollback_tmp=$(mktemp -d)
trap 'rm -rf "$rollback_tmp"' EXIT
historical="$rollback_tmp/historical"
prepared=${ROLLBACK_OUTPUT_DIR:-$rollback_tmp/prepared}
mkdir -p "$historical" "$prepared"
remote="${remote_name}:${bucket}"
history="catalog-history/${source_pair}"

for name in catalog-v1.json catalog-v1.sig catalog-v2.json catalog-v2.sig release-pair.json; do
  rclone copyto "$remote/$history/$name" "$historical/$name"
done
python3 "$script_dir/verify-ml-release-pair.py" "$historical" --expected-pair "$source_pair"
xcrun swift "$script_dir/verify-ml-catalog-signature.swift" \
  "$historical/catalog-v1.json" "$historical/catalog-v1.sig" "$public_key_base64"
xcrun swift "$script_dir/verify-ml-catalog-signature.swift" \
  "$historical/catalog-v2.json" "$historical/catalog-v2.sig" "$public_key_base64"

xcrun swift "$script_dir/prepare-ml-model-rollback.swift" \
  --catalog-v1 "$historical/catalog-v1.json" \
  --catalog-v2 "$historical/catalog-v2.json" \
  --private-key "$private_key" \
  --output "$prepared" \
  --catalog-sequence "$new_sequence" \
  --repository-revision "$repository_revision" \
  --released-at "$released_at" \
  --source-pair "$source_pair"

new_pair=$(tr -d '\r\n' < "$prepared/release-pair.sha256")
python3 "$script_dir/verify-ml-release-pair.py" "$prepared" --expected-pair "$new_pair"
xcrun swift "$script_dir/verify-ml-catalog-signature.swift" \
  --pointer "$prepared/active-pair.json" "$public_key_base64"
xcrun swift "$script_dir/verify-ml-catalog-signature.swift" \
  "$prepared/catalog-v1.json" "$prepared/catalog-v1.sig" "$public_key_base64"
xcrun swift "$script_dir/verify-ml-catalog-signature.swift" \
  "$prepared/catalog-v2.json" "$prepared/catalog-v2.sig" "$public_key_base64"

r2_request() {
  local method=$1 key=$2 file=${3:-} immutable=${4:-0} maximum_bytes=${5:-0}
  # The signer reads no input; keep it away from the stdin of the caller's read loop.
  python3 "$script_dir/r2_request.py" "$method" "$bucket" "$key" "$file" "$immutable" "$maximum_bytes" </dev/null
}

artifact_rows="$rollback_tmp/rollback-artifacts.tsv"
python3 "$script_dir/verify-ml-release-pair.py" \
  --artifact-list "$historical/catalog-v2.json" \
  > "$artifact_rows"

artifact_verify="$rollback_tmp/rollback-artifact"
while IFS=$'\t' read -r key expected_hash expected_bytes; do
  r2_request GET "$key" "$artifact_verify" 0 "$expected_bytes"
  actual_hash=$(shasum -a 256 "$artifact_verify" | awk '{print $1}')
  actual_bytes=$(stat -f %z "$artifact_verify")
  [[ "$actual_hash" == "$expected_hash" && "$actual_bytes" == "$expected_bytes" ]] || {
    echo "Rollback artifact is unavailable or corrupt: $key" >&2
    exit 1
  }
  rm -f -- "$artifact_verify"
done < "$artifact_rows"

upload_immutable() {
  local source=$1 key=$2 expected_hash expected_bytes verify actual_hash actual_bytes
  expected_hash=$(shasum -a 256 "$source" | awk '{print $1}')
  expected_bytes=$(stat -f %z "$source")
  verify="$rollback_tmp/verify-$expected_hash-$RANDOM"
  if r2_request PUT "$key" "$source" 1; then
    :
  elif [[ $? == 42 ]]; then
    echo "Conditional PutObject found existing $key; verifying its bytes" >&2
    r2_request GET "$key" "$verify" 0 "$expected_bytes" || {
      echo "Immutable object is unavailable: $key" >&2
      exit 1
    }
  else
    echo "Conditional PutObject failed for $key" >&2
    exit 1
  fi
  if [[ ! -f "$verify" ]]; then
    r2_request GET "$key" "$verify" 0 "$expected_bytes"
  fi
  actual_hash=$(shasum -a 256 "$verify" | awk '{print $1}')
  actual_bytes=$(stat -f %z "$verify")
  [[ "$actual_hash" == "$expected_hash" && "$actual_bytes" == "$expected_bytes" ]] || {
    echo "Immutable object mismatch: $key" >&2
    exit 1
  }
}

publish_mutable_verified() {
  local source=$1 key=$2 expected_hash expected_bytes verify actual_hash actual_bytes
  expected_hash=$(shasum -a 256 "$source" | awk '{print $1}')
  expected_bytes=$(stat -f %z "$source")
  verify="$rollback_tmp/mutable-$expected_hash"
  r2_request PUT "$key" "$source" 0
  r2_request GET "$key" "$verify" 0 "$expected_bytes"
  actual_hash=$(shasum -a 256 "$verify" | awk '{print $1}')
  actual_bytes=$(stat -f %z "$verify")
  [[ "$actual_hash" == "$expected_hash" && "$actual_bytes" == "$expected_bytes" ]] || {
    echo "Mutable catalog object mismatch: $key" >&2
    exit 1
  }
  rm -f -- "$verify"
}

for name in catalog-v1.sig catalog-v1.json catalog-v2.sig catalog-v2.json release-pair.json; do
  upload_immutable "$prepared/$name" "catalog-history/$new_pair/$name"
done
upload_immutable "$prepared/release-pair.json" "model-releases/$new_pair/release-pair.json"

publish_mutable_verified "$prepared/catalog-v1.sig" catalog-v1.sig
publish_mutable_verified "$prepared/catalog-v1.json" catalog-v1.json
publish_mutable_verified "$prepared/catalog-v2.sig" catalog-v2.sig
publish_mutable_verified "$prepared/catalog-v2.json" catalog-v2.json
publish_mutable_verified "$prepared/active-pair.json" active-pair.json

echo "Published rollback pair $new_pair at sequence $new_sequence from $source_pair"
print -r -- "$new_pair" > "$rollback_tmp/new-pair.sha256"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "pair_id=$new_pair" >> "$GITHUB_OUTPUT"
fi
