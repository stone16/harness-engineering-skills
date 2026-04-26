#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fake_gh="$tmpdir/gh"
filed="$tmpdir/index.md"
body="$tmpdir/body.md"

printf 'body\n' > "$body"

cat > "$fake_gh" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == "repo view" ]]; then printf 'host/repo\n'; exit 0; fi
if [[ "$1 $2" == "label view" ]]; then exit 0; fi
if [[ "$1 $2" == "label create" ]]; then exit 0; fi
if [[ "$1 $2" == "issue create" ]]; then
  if [[ " $* " == *" --repo stone16/harness-engineering-skills "* ]]; then
    printf 'https://github.com/stone16/harness-engineering-skills/issues/10\n'
  else
    printf 'https://github.com/host/repo/issues/20\n'
  fi
  exit 0
fi
if [[ "$1 $2" == "issue edit" ]]; then exit 0; fi
exit 99
SH
chmod +x "$fake_gh"

run_case() {
  local target="$1"
  local index="$2"
  PATH="$tmpdir:$PATH" \
    TARGET_REPO="$target" \
    PROPOSAL_INDEX="$index" \
    TITLE="Title $index" \
    BODY_FILE="$body" \
    FILED_ISSUES_FILE="$filed" \
    HARNESS_TARGET_REPO="stone16/harness-engineering-skills" \
    "$repo_root/scripts/file-retro-issue.sh"
}

run_case "host" "host"
run_case "Harness " "Harness"
run_case "both" "both"
run_case "invalid" "invalid"

PATH="$tmpdir:$PATH" \
  PROPOSAL_INDEX="missing" \
  TITLE="Title missing" \
  BODY_FILE="$body" \
  FILED_ISSUES_FILE="$filed" \
  HARNESS_TARGET_REPO="stone16/harness-engineering-skills" \
  "$repo_root/scripts/file-retro-issue.sh"

PATH="/usr/bin:/bin" \
  TARGET_REPO="host" \
  PROPOSAL_INDEX="nogh" \
  TITLE="Title nogh" \
  BODY_FILE="$body" \
  FILED_ISSUES_FILE="$filed" \
  HARNESS_TARGET_REPO="stone16/harness-engineering-skills" \
  "$repo_root/scripts/file-retro-issue.sh"

expected="$tmpdir/expected.md"
cat > "$expected" <<'EOF'
## Filed Issues
- Proposal host (host): https://github.com/host/repo/issues/20
- Proposal Harness (harness): https://github.com/stone16/harness-engineering-skills/issues/10
- Proposal both (both): https://github.com/stone16/harness-engineering-skills/issues/10 | https://github.com/host/repo/issues/20
- Proposal invalid (skipped, invalid target_repo='invalid'): Title invalid
- Proposal missing (skipped, invalid target_repo=''): Title missing
- Proposal nogh (skipped): gh CLI unavailable
EOF

diff -u "$expected" "$filed"
echo "file-retro-issue smoke test passed"
