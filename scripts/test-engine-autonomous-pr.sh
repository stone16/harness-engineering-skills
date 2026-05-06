#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="$repo_root/plugins/harness-engineering-skills/skills/harness/scripts/harness-engine.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

setup_repo() {
  local workdir="$1"
  local origin="${workdir}-origin.git"
  git init -q --bare "$origin"
  mkdir -p "$workdir"
  (
    cd "$workdir"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Harness Test"
    echo root > README.md
    git add README.md
    git commit -q -m "initial"
    git remote add origin "$origin"
    git push -q -u origin main
    git checkout -q -b feature/autonomous-pr
    mkdir -p .harness/autonomous-pr-test
    cat > .harness/autonomous-pr-test/git-state.json <<'JSON'
{
  "task_id": "autonomous-pr-test",
  "task_start_sha": "unused",
  "phase": "full-verify",
  "checkpoints": {},
  "e2e_baseline_sha": "",
  "e2e_final_sha": "",
  "review_loop_status": "SKIPPED",
  "review_loop_session_id": "",
  "review_loop_summary_file": "",
  "review_loop_rounds_file": "",
  "full_verify_baseline_sha": "",
  "full_verify_final_sha": "",
  "full_verify_status": "COMPLETE",
  "pr_url": ""
}
JSON
  )
}

install_gh_stub() {
  local bindir="$1"
  local log_file="$2"
  mkdir -p "$bindir"
  cat > "$bindir/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_STUB_LOG"
if [[ "$1" == "pr" && "$2" == "create" ]]; then
  echo "https://github.com/example/repo/pull/123"
else
  echo "unexpected gh invocation: $*" >&2
  exit 1
fi
STUB
  chmod +x "$bindir/gh"
}

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    echo "missing expected text in $file: $needle" >&2
    exit 1
  fi
}

config_repo="$tmpdir/config"
setup_repo "$config_repo"
(
  cd "$config_repo"
  "$engine" read-config > read-config.out
  assert_contains read-config.out "AUTONOMOUS_PR=true"
  mkdir -p .harness
  printf '{"autonomous_pr": false}\n' > .harness/config.json
  "$engine" read-config > read-config-false.out
  assert_contains read-config-false.out "AUTONOMOUS_PR=false"
)

true_repo="$tmpdir/true"
setup_repo "$true_repo"
true_bin="$tmpdir/true-bin"
true_log="$tmpdir/true-gh.log"
: > "$true_log"
install_gh_stub "$true_bin" "$true_log"
(
  cd "$true_repo"
  if PATH="$true_bin:$PATH" GH_STUB_LOG="$true_log" \
    "$engine" create-pr --task-id autonomous-pr-test --base > missing-base.out 2> missing-base.err; then
    echo "create-pr succeeded despite missing --base value" >&2
    cat missing-base.out >&2
    cat missing-base.err >&2
    exit 1
  fi
  assert_contains missing-base.err "Error: --base requires a value"

  PATH="$true_bin:$PATH" GH_STUB_LOG="$true_log" \
    "$engine" create-pr --task-id autonomous-pr-test --base main --title "Autonomous PR" --body "Default autonomous body" > create-pr.out
  assert_contains create-pr.out "CREATE_PR_OK"
  assert_contains create-pr.out "AUTONOMOUS_PR=true"
  assert_contains create-pr.out "PR_URL=https://github.com/example/repo/pull/123"
  git ls-remote --exit-code --heads origin feature/autonomous-pr >/dev/null
)
if [[ "$(grep -c '^pr create' "$true_log")" -ne 1 ]]; then
  echo "expected autonomous_pr=true to call gh pr create exactly once" >&2
  exit 1
fi

false_repo="$tmpdir/false"
setup_repo "$false_repo"
false_bin="$tmpdir/false-bin"
false_log="$tmpdir/false-gh.log"
: > "$false_log"
install_gh_stub "$false_bin" "$false_log"
(
  cd "$false_repo"
  mkdir -p .harness
  printf '{"autonomous_pr": false}\n' > .harness/config.json
  PATH="$false_bin:$PATH" GH_STUB_LOG="$false_log" \
    "$engine" create-pr --task-id autonomous-pr-test --base main --title "Manual PR" --body "Manual handoff body" > create-pr.out
  assert_contains create-pr.out "PR_HANDOFF_OK"
  handoff=".harness/autonomous-pr-test/pr-handoff.md"
  assert_contains "$handoff" "Title: Manual PR"
  assert_contains "$handoff" "Body:"
  assert_contains "$handoff" "Manual handoff body"
  assert_contains "$handoff" "Base branch: main"
  assert_contains "$handoff" "Head branch: feature/autonomous-pr"
  assert_contains "$handoff" "git push -u origin HEAD"
  assert_contains "$handoff" "gh pr create --base \"main\" --head \"feature/autonomous-pr\" --title \"Manual PR\" --body-file \".harness/autonomous-pr-test/pr-body.md\""

  printf 'stale\n' > "$handoff"
  PATH="$false_bin:$PATH" GH_STUB_LOG="$false_log" \
    "$engine" create-pr --task-id autonomous-pr-test --base main --title "Manual PR" --body "Manual handoff body" > create-pr-retry.out 2> create-pr-retry.err
  assert_contains create-pr-retry.err "Warning: pr-handoff.md exists; overwriting"
  assert_contains "$handoff" "Manual handoff body"
)
if [[ -s "$false_log" ]]; then
  echo "expected autonomous_pr=false to skip gh pr create, got:" >&2
  cat "$false_log" >&2
  exit 1
fi

echo "engine autonomous_pr test passed"
