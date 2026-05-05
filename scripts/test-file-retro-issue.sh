#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fake_gh="$tmpdir/gh"
filed="$tmpdir/index.md"
body="$tmpdir/body.md"
stdout_log="$tmpdir/stdout.log"
gh_log="$tmpdir/gh.log"
retry_state="$tmpdir/retry-state"

printf 'body\n' > "$body"
: > "$stdout_log"
: > "$gh_log"

cat > "$fake_gh" <<'SH'
#!/usr/bin/env bash
mode="${FAKE_GH_MODE:-ok}"
printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
if [[ "$1 $2" == "repo view" ]]; then
  [[ "$mode" == "host_unresolved" ]] && exit 1
  printf 'host/repo\n'
  exit 0
fi
if [[ "$1 $2" == "label view" ]]; then
  [[ "$mode" == "label_fail" ]] && exit 1
  [[ "$mode" == "retry_then_ok" ]] && exit 1
  exit 0
fi
if [[ "$1 $2" == "label create" ]]; then
  [[ "$mode" == "label_fail" ]] && exit 1
  if [[ "$mode" == "retry_then_ok" ]]; then
    state="${FAKE_RETRY_STATE:?}"
    count="$(cat "$state" 2>/dev/null || printf '0')"
    count=$((count + 1))
    printf '%s' "$count" > "$state"
    [[ "$count" -lt 3 ]] && exit 1
  fi
  exit 0
fi
if [[ "$1 $2" == "issue create" ]]; then
  [[ "$mode" == "both_create_fail" ]] && exit 1
  if [[ " $* " == *" --repo stone16/harness-engineering-skills "* ]]; then
    [[ "$mode" == "harness_create_fail" || "$mode" == "annotation_fail" ]] && exit 1
    printf 'https://github.com/stone16/harness-engineering-skills/issues/10\n'
  else
    [[ "$mode" == "host_create_fail" ]] && exit 1
    printf 'https://github.com/host/repo/issues/20\n'
  fi
  exit 0
fi
if [[ "$1 $2" == "issue edit" ]]; then
  [[ "$mode" == "annotation_fail" ]] && exit 1
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
    FAKE_GH_LOG="$gh_log" \
    FAKE_RETRY_STATE="$retry_state" \
    HARNESS_RETRY_SLEEP="0" \
    TARGET_REPO="$target" \
    PROPOSAL_INDEX="$index" \
    TITLE="Title $index" \
    BODY_FILE="$body" \
    FILED_ISSUES_FILE="$filed" \
    HARNESS_TARGET_REPO="stone16/harness-engineering-skills" \
    "$repo_root/scripts/file-retro-issue.sh" >> "$stdout_log"
}

run_case "host" "host"
run_case "Harness " "Harness"
run_case "both" "both"
run_case "invalid" "invalid"
run_case "both" "bothNoHost" "host_unresolved"
run_case "host" "hostNoHost" "host_unresolved"
run_case "host" "hostCreateFail" "host_create_fail"
run_case "both" "partialCreate" "harness_create_fail"
run_case "both" "annotationFail" "annotation_fail"
run_case "both" "partialHostCreate" "host_create_fail"
run_case "both" "partialEdit" "partial_edit"
run_case "host" "labelFail" "label_fail"
run_case "harness" "labelFailHarness" "label_fail"
run_case "both" "labelFailBoth" "label_fail"
run_case "both" "bothCreateFail" "both_create_fail"
run_case "\`harness\`" "decoratedBacktick"
run_case '"host"' "decoratedDoubleQuote"
run_case "both # route to both repos" "decoratedComment"
run_case "frontend" "invalidFrontend"
: > "$retry_state"
run_case "harness" "retryThenOk" "retry_then_ok"

TMPDIR="$body" run_case "both" "mktempFail"

PATH="$tmpdir:$PATH" \
  FAKE_GH_LOG="$gh_log" \
  FAKE_RETRY_STATE="$retry_state" \
  HARNESS_RETRY_SLEEP="0" \
  PROPOSAL_INDEX="missing" \
  TITLE="Title missing" \
  BODY_FILE="$body" \
  FILED_ISSUES_FILE="$filed" \
  HARNESS_TARGET_REPO="stone16/harness-engineering-skills" \
  "$repo_root/scripts/file-retro-issue.sh" >> "$stdout_log"

PATH="/usr/bin:/bin" \
  FAKE_GH_LOG="$gh_log" \
  FAKE_RETRY_STATE="$retry_state" \
  HARNESS_RETRY_SLEEP="0" \
  TARGET_REPO="host" \
  PROPOSAL_INDEX="nogh" \
  TITLE="Title nogh" \
  BODY_FILE="$body" \
  FILED_ISSUES_FILE="$filed" \
  HARNESS_TARGET_REPO="stone16/harness-engineering-skills" \
  "$repo_root/scripts/file-retro-issue.sh" >> "$stdout_log"

expected="$tmpdir/expected.md"
cat > "$expected" <<'EOF'
## Filed Issues
- Proposal host (host): https://github.com/host/repo/issues/20
- Proposal Harness (harness): https://github.com/stone16/harness-engineering-skills/issues/10
- Proposal both (both): https://github.com/stone16/harness-engineering-skills/issues/10 | https://github.com/host/repo/issues/20
- Proposal invalid (skipped, invalid target_repo='invalid'): Title invalid
- Proposal bothNoHost (both, host repo unresolved): https://github.com/stone16/harness-engineering-skills/issues/10 | no-host-url
- Proposal hostNoHost (skipped, host repo unresolved): Title hostNoHost
- Proposal hostCreateFail (skipped, host create failed): Title hostCreateFail
- Proposal partialCreate (both, partial create): no-harness-url | https://github.com/host/repo/issues/20
- Proposal annotationFail (both, annotation failed): https://github.com/host/repo/issues/20
- Proposal annotationFail (both, partial create): no-harness-url | https://github.com/host/repo/issues/20
- Proposal partialHostCreate (both, partial create): https://github.com/stone16/harness-engineering-skills/issues/10 | no-host-url
- Proposal partialEdit (both, partial edit harness=failed host=ok): https://github.com/stone16/harness-engineering-skills/issues/10 | https://github.com/host/repo/issues/20
- Proposal labelFail (host, label not applied): https://github.com/host/repo/issues/20
- Proposal labelFailHarness (harness, label not applied): https://github.com/stone16/harness-engineering-skills/issues/10
- Proposal labelFailBoth (both, labels harness=false host=false): https://github.com/stone16/harness-engineering-skills/issues/10 | https://github.com/host/repo/issues/20
- Proposal bothCreateFail (both, partial create): no-harness-url | no-host-url
- Proposal decoratedBacktick (harness): https://github.com/stone16/harness-engineering-skills/issues/10
- Proposal decoratedDoubleQuote (host): https://github.com/host/repo/issues/20
- Proposal decoratedComment (both): https://github.com/stone16/harness-engineering-skills/issues/10 | https://github.com/host/repo/issues/20
- Proposal invalidFrontend (skipped, invalid target_repo='frontend'): Title invalidFrontend
- Proposal retryThenOk (harness): https://github.com/stone16/harness-engineering-skills/issues/10
- Proposal mktempFail (both, cross-link skipped, mktemp failed): https://github.com/stone16/harness-engineering-skills/issues/10 | https://github.com/host/repo/issues/20
- Proposal missing (skipped, invalid target_repo=''): Title missing
- Proposal nogh (skipped): gh CLI unavailable
EOF

diff -u "$expected" "$filed"

invocations="$(wc -l < "$stdout_log" | tr -d ' ')"
if [[ "$invocations" != "23" ]]; then
  echo "expected one stdout summary per invocation; got $invocations" >&2
  cat "$stdout_log" >&2
  exit 1
fi
if grep -Ev '^proposal=[^[:space:]]+ target=(host|harness|both|invalid|missing) url=(https://github.com/[^[:space:]]+|none) labels=(ok|partial|skipped)$' "$stdout_log"; then
  echo "stdout summary shape mismatch" >&2
  exit 1
fi
grep -q '^proposal=retryThenOk target=harness url=https://github.com/stone16/harness-engineering-skills/issues/10 labels=ok$' "$stdout_log"

: > "$gh_log"
PATH="$tmpdir:$PATH"
FAKE_GH_LOG="$gh_log"
FAKE_RETRY_STATE="$retry_state"
FAKE_GH_MODE="ok"
HARNESS_RETRY_SLEEP="0"
BODY_FILE="$body"
FILED_ISSUES_FILE="$filed"
TARGET_REPO="harness"
PROPOSAL_INDEX="cache"
TITLE="Title cache"
HOST_TARGET_REPO="host/repo"
HARNESS_TARGET_REPO="stone16/harness-engineering-skills"
HARNESS_FILE_RETRO_ISSUE_SOURCE_ONLY=true
export FAKE_GH_LOG FAKE_RETRY_STATE FAKE_GH_MODE HARNESS_RETRY_SLEEP
source "$repo_root/scripts/file-retro-issue.sh"
ensure_label harness
ensure_label harness
label_view_count="$(grep -c '^label view harness-retro --repo stone16/harness-engineering-skills$' "$gh_log" || true)"
if [[ "$label_view_count" != "1" ]]; then
  echo "expected label cache to avoid second label view; got $label_view_count" >&2
  cat "$gh_log" >&2
  exit 1
fi

: > "$gh_log"
run_case_with_label_ready() {
  PATH="$tmpdir:$PATH" \
    TMPDIR="${TMPDIR-}" \
    FAKE_GH_MODE="ok" \
    FAKE_GH_LOG="$gh_log" \
    FAKE_RETRY_STATE="$retry_state" \
    HARNESS_RETRY_SLEEP="0" \
    LABEL_READY="true" \
    TARGET_REPO="harness" \
    PROPOSAL_INDEX="labelReady" \
    TITLE="Title labelReady" \
    BODY_FILE="$body" \
    FILED_ISSUES_FILE="$filed" \
    HARNESS_TARGET_REPO="stone16/harness-engineering-skills" \
    "$repo_root/scripts/file-retro-issue.sh" >/dev/null
}
run_case_with_label_ready
if grep -E '^label (view|create) harness-retro' "$gh_log"; then
  echo "LABEL_READY=true should skip label view/create" >&2
  exit 1
fi
echo "file-retro-issue smoke test passed"
