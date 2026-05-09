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

setup_repo() {
  local workdir="$1"
  local task="$2"
  local member_count="$3"
  local config_json="${4:-}"
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
    if [[ -n "$config_json" ]]; then
      printf '%s\n' "$config_json" > .harness/config.json
    fi
    cat > ".harness/$task/git-state.json" <<JSON
{
  "task_id": "$task",
  "task_start_sha": "unused",
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
    {
      cat <<SPEC
---
task_id: $task
title: cohort config fixture
version: 1
status: approved
branch: main
---

## Checkpoints
SPEC
      for i in $(seq 1 "$member_count"); do
        cp=$(printf '%02d' "$i")
        cat <<SPEC

### Checkpoint ${cp}: member ${cp}

- Scope: member ${cp}
- Depends on: none
- Type: infrastructure
- parallel_group: A
- Acceptance criteria:
  - [ ] member ${cp}
- Files of interest:
  - file-${cp}.txt
- Effort estimate: S
SPEC
      done
    } > ".harness/$task/spec.md"
  )
}

assert_default_true_accepts_multi_member() {
  local task="cohort-config-default-true"
  local repo="$tmpdir/default-true"
  setup_repo "$repo" "$task" 2
  (
    cd "$repo"
    "$engine" read-config > read-config.out
    assert_contains read-config.out "ENABLE_PARALLEL_COHORTS=true"
    assert_contains read-config.out "MAX_PARALLEL_COHORT_SIZE=4"
    "$engine" begin-cohort --task-id "$task" --group A > begin.out
    assert_contains begin.out "BEGIN_COHORT_OK"
  )
}

assert_disabled_rejects_multi_member() {
  local task="cohort-config-disabled"
  local repo="$tmpdir/disabled"
  setup_repo "$repo" "$task" 2 '{"enable_parallel_cohorts": false}'
  (
    cd "$repo"
    if "$engine" begin-cohort --task-id "$task" --group A > begin.out 2> begin.err; then
      echo "begin-cohort accepted multi-member cohort while disabled" >&2
      exit 1
    fi
    assert_contains begin.err "Error: enable_parallel_cohorts=false; cohort A has 2>1 members"
  )
}

assert_cap_rejects_oversized_cohort() {
  local task="cohort-config-cap"
  local repo="$tmpdir/cap"
  setup_repo "$repo" "$task" 3 '{"max_parallel_cohort_size": 2}'
  (
    cd "$repo"
    if "$engine" begin-cohort --task-id "$task" --group A > begin.out 2> begin.err; then
      echo "begin-cohort accepted cohort above cap" >&2
      exit 1
    fi
    assert_contains begin.err "Error: cohort A has 3 members; max_parallel_cohort_size=2"
  )
}

assert_default_cap_accepts_four_members() {
  local task="cohort-config-four"
  local repo="$tmpdir/four"
  setup_repo "$repo" "$task" 4
  (
    cd "$repo"
    "$engine" begin-cohort --task-id "$task" --group A > begin.out
    assert_contains begin.out "BEGIN_COHORT_OK"
    assert_contains begin.out "MEMBERS=01,02,03,04"
  )
}

assert_default_true_accepts_multi_member
assert_disabled_rejects_multi_member
assert_cap_rejects_oversized_cohort
assert_default_cap_accepts_four_members

echo "engine cohort config test passed"
