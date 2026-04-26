#!/usr/bin/env bash
set -euo pipefail

quick_ref="plugins/harness-engineering-skills/skills/harness/references/protocol-quick-ref.md"

normalize_repo_url() {
  local url="$1"
  case "$url" in
    git@github.com:*)
      url="https://github.com/${url#git@github.com:}"
      ;;
  esac
  printf '%s\n' "${url%.git}"
}

remote_url="$(git config --get remote.origin.url)"
remote_url="$(normalize_repo_url "$remote_url")"

quick_ref_url="$(
  grep -m1 '^HARNESS_TARGET_REPO=' "$quick_ref" |
    sed 's/^HARNESS_TARGET_REPO="${HARNESS_TARGET_REPO:-//; s/}"$//'
)"

if [[ -z "$quick_ref_url" ]]; then
  echo "Could not find HARNESS_TARGET_REPO default in $quick_ref" >&2
  exit 1
fi

quick_ref_url="$(normalize_repo_url "$quick_ref_url")"

if [[ "$quick_ref_url" != "$remote_url" ]]; then
  echo "HARNESS_TARGET_REPO default does not match origin remote" >&2
  echo "quick-ref: $quick_ref_url" >&2
  echo "origin:    $remote_url" >&2
  exit 1
fi

echo "HARNESS_TARGET_REPO default matches origin: $quick_ref_url"
