#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="$repo_root/plugins/harness-engineering-skills/skills/harness/scripts/harness-engine.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

assert_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file" || {
    echo "missing expected text in $file: $needle" >&2
    exit 1
  }
}

source_engine_functions() {
  # Load helper functions/constants without executing the engine dispatch table.
  # shellcheck disable=SC1090
  source <(sed '/^# ============ helpers end ============/,$d' "$engine")
}

setup_repo() {
  local workdir="$1"
  local task="$2"
  local timeout="${3:-120}"
  local origin="${workdir}-origin.git"
  git init -q --bare "$origin"
  git clone -q "$origin" "$workdir"
  (
    cd "$workdir"
    git checkout -q -b main
    git config user.email "test@example.com"
    git config user.name "Harness Test"
    echo root > README.md
    git add README.md
    git commit -q -m "initial"
    git push -q -u origin main
    mkdir -p ".harness/$task"
    printf '{"commit_lock_timeout_seconds": %s}\n' "$timeout" > .harness/config.json
    baseline="$(git rev-parse HEAD)"
    cat > ".harness/$task/git-state.json" <<JSON
{
  "task_id": "$task",
  "task_start_sha": "$baseline",
  "phase": "checkpoints",
  "checkpoints": {},
  "e2e_baseline_sha": "",
  "e2e_final_sha": "",
  "review_loop_status": "",
  "review_loop_session_id": "",
  "review_loop_summary_file": "",
  "review_loop_rounds_file": "",
  "full_verify_baseline_sha": "",
  "full_verify_final_sha": "",
  "full_verify_status": "",
  "pr_url": ""
}
JSON
  )
}

assert_read_config_emits_timeout() {
  local task="commit-lock-config"
  local repo="$tmpdir/config"
  setup_repo "$repo" "$task" 3
  (
    cd "$repo"
    "$engine" read-config > read-config.out
    assert_contains read-config.out "COMMIT_LOCK_TIMEOUT_SECONDS=3"
  )
}

assert_sequential_lock_acquire_release() {
  local task="commit-lock-sequential"
  local repo="$tmpdir/sequential"
  setup_repo "$repo" "$task" 5
  (
    cd "$repo"
    source_engine_functions
    set +e
    acquire_commit_lock "$task" bash -c 'echo ran > callback.out; exit 7'
    status=$?
    set -e
    [[ "$status" -eq 7 ]] || {
      echo "expected callback exit code 7, got $status" >&2
      exit 1
    }
    assert_contains callback.out "ran"
    [[ -f ".harness/$task/.commit.lock" ]] || {
      echo "lock file was not created" >&2
      exit 1
    }
  )
}

assert_concurrent_git_commits_serialize() {
  local task="commit-lock-concurrent"
  local repo="$tmpdir/concurrent"
  setup_repo "$repo" "$task" 10
  (
    cd "$repo"
    source_engine_functions
    : > order.log
    acquire_commit_lock "$task" bash -c 'echo first-start >> order.log; sleep 1; echo one > one.txt; git add one.txt; git commit -q -m "first locked commit"; echo first-end >> order.log' &
    first_pid=$!
    sleep 0.2
    acquire_commit_lock "$task" bash -c 'echo second-start >> order.log; echo two > two.txt; git add two.txt; git commit -q -m "second locked commit"; echo second-end >> order.log' &
    second_pid=$!
    wait "$first_pid"
    wait "$second_pid"
    first_end_line=$(grep -n '^first-end$' order.log | cut -d: -f1)
    second_start_line=$(grep -n '^second-start$' order.log | cut -d: -f1)
    [[ "$second_start_line" -gt "$first_end_line" ]] || {
      echo "second callback started before first callback released lock" >&2
      cat order.log >&2
      exit 1
    }
    git log --oneline --format=%s -2 > commits.log
    assert_contains commits.log "first locked commit"
    assert_contains commits.log "second locked commit"
  )
}

assert_timeout_exhaustion() {
  local task="commit-lock-timeout"
  local repo="$tmpdir/timeout"
  setup_repo "$repo" "$task" 1
  (
    cd "$repo"
    source_engine_functions
    acquire_commit_lock "$task" bash -c 'sleep 3' &
    holder_pid=$!
    sleep 0.2
    set +e
    acquire_commit_lock "$task" bash -c 'echo should-not-run > timeout.out' 2> timeout.err
    status=$?
    set -e
    wait "$holder_pid"
    [[ "$status" -ne 0 ]] || {
      echo "expected lock acquisition to time out" >&2
      exit 1
    }
    [[ ! -f timeout.out ]] || {
      echo "timed out callback unexpectedly ran" >&2
      exit 1
    }
    if ! command -v flock >/dev/null 2>&1; then
      assert_contains timeout.err "using mkdir fallback commit lock"
    fi
  )
}

assert_public_with_commit_lock_command() {
  local task="commit-lock-public"
  local repo="$tmpdir/public"
  setup_repo "$repo" "$task" 5
  (
    cd "$repo"
    "$engine" with-commit-lock --task-id "$task" -- bash -c 'echo public-lock-ran > public.out'
    assert_contains public.out "public-lock-ran"
    [[ -f ".harness/$task/.commit.lock" ]] || {
      echo "with-commit-lock did not create the public lock file" >&2
      exit 1
    }
  )
}

assert_read_config_emits_timeout
assert_sequential_lock_acquire_release
assert_concurrent_git_commits_serialize
assert_timeout_exhaustion
assert_public_with_commit_lock_command

echo "engine commit lock test passed"
