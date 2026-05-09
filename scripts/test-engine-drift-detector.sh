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
  local origin="${workdir}-origin.git"
  git init -q --bare "$origin"
  git clone -q "$origin" "$workdir"
  (
    cd "$workdir"
    git checkout -q -b main
    git config user.email "test@example.com"
    git config user.name "Harness Test"
    echo root > README.md
    echo baseline-a > a.txt
    echo baseline-b > b.txt
    git add README.md a.txt b.txt
    git commit -q -m "initial"
    git push -q -u origin main
    mkdir -p ".harness/$task"
  )
}

write_spec() {
  local repo="$1"
  local task="$2"
  cat > "$repo/.harness/$task/spec.md" <<'SPEC'
---
task_id: drift-fixture
title: drift detector fixture
version: 1
status: approved
branch: main
---

## Checkpoints

### Checkpoint 01: first

- Scope: first
- Depends on: none
- Type: infrastructure
- parallel_group: A
- Acceptance criteria:
  - [ ] first
- Files of interest:
  - a.txt
- Effort estimate: S

### Checkpoint 02: second

- Scope: second
- Depends on: none
- Type: infrastructure
- parallel_group: A
- Acceptance criteria:
  - [ ] second
- Files of interest:
  - b.txt
- Effort estimate: S
SPEC
}

write_state() {
  local repo="$1"
  local task="$2"
  local cohort_cp01="${3-A}"
  local baseline
  baseline="$(cd "$repo" && git rev-parse HEAD)"
  cat > "$repo/.harness/$task/git-state.json" <<JSON
{
  "task_id": "$task",
  "task_start_sha": "$baseline",
  "phase": "checkpoints",
  "checkpoints": {
    "01": {
      "baseline_sha": "$baseline",
      "cohort": "$cohort_cp01",
      "iterations": {}
    },
    "02": {
      "baseline_sha": "$baseline",
      "cohort": "A",
      "iterations": {}
    }
  },
  "cohorts": {
    "A": {
      "members": ["01", "02"],
      "status": "pending",
      "baseline_sha": "$baseline"
    }
  },
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
}

assert_serial_checkpoint_no_drift_artifact() {
  local task="drift-serial"
  local repo="$tmpdir/serial"
  setup_repo "$repo" "$task"
  write_spec "$repo" "$task"
  write_state "$repo" "$task" ""
  (
    cd "$repo"
    echo changed > b.txt
    git add b.txt
    git commit -q -m "serial touches peer-looking file"
    "$engine" end-iteration --task-id "$task" --checkpoint 01 > end.out
    [[ ! -f ".harness/$task/checkpoints/01/iter-1/drift-event.md" ]] || {
      echo "serial checkpoint unexpectedly wrote drift-event.md" >&2
      exit 1
    }
  )
}

assert_cohort_own_file_no_drift_artifact() {
  local task="drift-own-file"
  local repo="$tmpdir/own"
  setup_repo "$repo" "$task"
  write_spec "$repo" "$task"
  write_state "$repo" "$task"
  (
    cd "$repo"
    echo changed > a.txt
    git add a.txt
    git commit -q -m "cohort member touches own file"
    "$engine" end-iteration --task-id "$task" --checkpoint 01 > end.out
    [[ ! -f ".harness/$task/checkpoints/01/iter-1/drift-event.md" ]] || {
      echo "own-file edit unexpectedly wrote drift-event.md" >&2
      exit 1
    }
  )
}

assert_cohort_peer_file_writes_shadow_artifact() {
  local task="drift-peer-file"
  local repo="$tmpdir/peer"
  setup_repo "$repo" "$task"
  write_spec "$repo" "$task"
  write_state "$repo" "$task"
  (
    cd "$repo"
    echo changed > b.txt
    git add b.txt
    git commit -q -m "cohort member touches peer file"
    "$engine" end-iteration --task-id "$task" --checkpoint 01 > end.out
    event=".harness/$task/checkpoints/01/iter-1/drift-event.md"
    assert_contains "$event" "offending_path: b.txt"
    assert_contains "$event" "offending_checkpoint: 01"
    assert_contains "$event" "peer_checkpoint: 02"
    assert_contains "$event" "severity: shadow"
    assert_contains "$event" "detected_at:"
  )
}

assert_serial_checkpoint_no_drift_artifact
assert_cohort_own_file_no_drift_artifact
assert_cohort_peer_file_writes_shadow_artifact

echo "engine drift detector shadow test passed"
