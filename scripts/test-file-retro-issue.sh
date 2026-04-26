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
mode="${FAKE_GH_MODE:-ok}"
if [[ "$1 $2" == "repo view" ]]; then
  [[ "$mode" == "host_unresolved" ]] && exit 1
  printf 'host/repo\n'
  exit 0
fi
if [[ "$1 $2" == "label view" ]]; then
  [[ "$mode" == "label_fail" ]] && exit 1
  exit 0
fi
if [[ "$1 $2" == "label create" ]]; then
  [[ "$mode" == "label_fail" ]] && exit 1
  exit 0
fi
if [[ "$1 $2" == "issue create" ]]; then
  if [[ " $* " == *" --repo stone16/harness-engineering-skills "* ]]; then
    [[ "$mode" == "harness_create_fail" ]] && exit 1
    printf 'https://github.com/stone16/harness-engineering-skills/issues/10\n'
  else
    [[ "$mode" == "host_create_fail" ]] && exit 1
    printf 'https://github.com/host/repo/issues/20\n'
  fi
  exit 0
fi
if [[ "$1 $2" == "issue edit" ]]; then
  [[ "$mode" == "partial_edit" && "$3" == *"harness-engineering-skills"* ]] && exit 1
  exit 0
fi
exit 99
SH
chmod +x "$fake_gh"

run_case() {
  local target="$1"
  local index="$2"
  local mode="${3:-ok}"
  PATH="$tmpdir:$PATH" \
    TMPDIR="${TMPDIR-}" \
    FAKE_GH_MODE="$mode" \
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
run_case "both" "bothNoHost" "host_unresolved"
run_case "host" "hostCreateFail" "host_create_fail"
run_case "both" "partialCreate" "harness_create_fail"
run_case "both" "partialEdit" "partial_edit"
run_case "host" "labelFail" "label_fail"

TMPDIR="$body" run_case "both" "mktempFail"

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
- Proposal bothNoHost (both, host repo unresolved): https://github.com/stone16/harness-engineering-skills/issues/10 | no-host-url
- Proposal hostCreateFail (skipped, host create failed): Title hostCreateFail
- Proposal partialCreate (both, partial create): no-harness-url | https://github.com/host/repo/issues/20
- Proposal partialEdit (both, partial edit harness=failed host=ok): https://github.com/stone16/harness-engineering-skills/issues/10 | https://github.com/host/repo/issues/20
- Proposal labelFail (host, label not applied): https://github.com/host/repo/issues/20
- Proposal mktempFail (both, cross-link skipped, mktemp failed): https://github.com/stone16/harness-engineering-skills/issues/10 | https://github.com/host/repo/issues/20
- Proposal missing (skipped, invalid target_repo=''): Title missing
- Proposal nogh (skipped): gh CLI unavailable
EOF

diff -u "$expected" "$filed"
echo "file-retro-issue smoke test passed"
