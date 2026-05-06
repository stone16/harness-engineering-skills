#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
engine="$repo_root/plugins/harness-engineering-skills/skills/harness/scripts/harness-engine.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

origin="$tmpdir/origin.git"
work="$tmpdir/work"

git init --bare "$origin" >/dev/null
git clone "$origin" "$work" >/dev/null 2>&1

git -C "$work" config user.name "Harness Test"
git -C "$work" config user.email "harness-test@example.com"

printf 'root\n' > "$work/root.txt"
git -C "$work" add root.txt
git -C "$work" commit -m "root" >/dev/null
git -C "$work" branch -M main
git -C "$work" push origin main >/dev/null 2>&1
root_sha="$(git -C "$work" rev-parse HEAD)"

printf 'already merged\n' > "$work/already-merged.txt"
git -C "$work" add already-merged.txt
git -C "$work" commit -m "already merged upstream" >/dev/null
git -C "$work" push origin main >/dev/null 2>&1
merged_sha="$(git -C "$work" rev-parse HEAD)"

printf 'second upstream\n' > "$work/second-upstream.txt"
git -C "$work" add second-upstream.txt
git -C "$work" commit -m "second upstream" >/dev/null
git -C "$work" push origin main >/dev/null 2>&1

git -C "$work" checkout -b feature "$merged_sha" >/dev/null 2>&1
git -C "$work" update-ref refs/heads/main "$root_sha"

output="$(cd "$work" && "$engine" scope-check --base-branch main)"

printf '%s\n' "$output" | grep -q '^SCOPE_CHECK_OK$'
printf '%s\n' "$output" | grep -q '^BASE_REF=origin/main$'
printf '%s\n' "$output" | grep -q '^IN_SCOPE_FILE_COUNT=0$'

if printf '%s\n' "$output" | grep -q '^already-merged.txt$'; then
  echo "already-merged.txt should not appear when origin/main is fetched and used as base" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

git -C "$work" remote set-url origin "$tmpdir/missing-origin.git"
if (cd "$work" && "$engine" scope-check --base-branch main) > "$tmpdir/fetch-fail.out" 2> "$tmpdir/fetch-fail.err"; then
  echo "scope-check succeeded despite failed fetch" >&2
  cat "$tmpdir/fetch-fail.out" >&2
  cat "$tmpdir/fetch-fail.err" >&2
  exit 1
fi
grep -q "Error: failed to fetch origin/main" "$tmpdir/fetch-fail.err"

echo "scope-check base fetch test passed"
