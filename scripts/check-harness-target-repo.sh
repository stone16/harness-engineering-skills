#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fi

quick_ref="$repo_root/plugins/harness-engineering-skills/skills/harness/references/protocol-quick-ref.md"
if [[ ! -f "$quick_ref" ]]; then
  echo "Quick-ref not found: $quick_ref" >&2
  exit 1
fi

normalize_repo_url() {
  local url="$1"
  case "$url" in
    git@github.com:*)
      url="${url#git@github.com:}"
      ;;
    https://github.com/*)
      url="${url#https://github.com/}"
      ;;
  esac
  printf '%s\n' "${url%.git}"
}

remote_url="$(git -C "$repo_root" config --get remote.origin.url 2>/dev/null || true)"
if [[ -z "$remote_url" ]]; then
  echo "No origin remote found; run from inside the harness repository." >&2
  exit 1
fi
remote_url="$(normalize_repo_url "$remote_url")"

quick_ref_count="$(grep -c '^HARNESS_TARGET_REPO=' "$quick_ref" 2>/dev/null || true)"
if [[ "$quick_ref_count" != "1" ]]; then
  echo "Expected exactly one HARNESS_TARGET_REPO default in $quick_ref; found $quick_ref_count" >&2
  exit 1
fi

quick_ref_url="$(
  grep '^HARNESS_TARGET_REPO=' "$quick_ref" |
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
