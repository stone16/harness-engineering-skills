#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="$repo_root/plugins/harness-engineering-skills/skills/harness/scripts/harness-engine.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

source "$repo_root/scripts/lib/test-helpers.sh"

write_cohort_spec() {
  local repo="$1"
  local task="$2"
  cat > "$repo/.harness/$task/spec.md" <<'SPEC'
---
task_id: drift-fail
title: drift fail fixture
version: 1
status: approved
branch: main
---

## Checkpoints

### Checkpoint 01: first

- Scope: first
- Depends on: none
- Type: infrastructure
- **parallel_group**: A
- Acceptance criteria:
  - [ ] first
- Files of interest:
  - a.txt
- **Effort estimate**: S

### Checkpoint 02: second

- Scope: second
- Depends on: none
- Type: infrastructure
- **parallel_group**: A
- Acceptance criteria:
  - [ ] second
- Files of interest:
  - `b.txt`
- **Effort estimate**: S
SPEC
}

write_serial_spec() {
  local repo="$1"
  local task="$2"
  cat > "$repo/.harness/$task/spec.md" <<'SPEC'
---
task_id: drift-serial
title: drift serial fixture
version: 1
status: approved
branch: main
---

## Checkpoints

### Checkpoint 01: first

- Scope: first
- Depends on: none
- Type: infrastructure
- Acceptance criteria:
  - [ ] first
- Files of interest:
  - a.txt
- Effort estimate: S

### Checkpoint 02: second

- Scope: second
- Depends on: CP01
- Type: infrastructure
- Acceptance criteria:
  - [ ] second
- Files of interest:
  - b.txt
- Effort estimate: S
SPEC
}

assert_cohort_peer_file_fails_iteration() {
  local task="drift-fail"
  local repo="$tmpdir/fail"
  setup_repo "$repo" "$task"
  write_cohort_spec "$repo" "$task"
  (
    cd "$repo"
    "$engine" init --task-id "$task" > init.out
    "$engine" begin-cohort --task-id "$task" --group A > begin-cohort.out
    "$engine" begin-checkpoint --task-id "$task" --checkpoint 01 > begin-01.out
    "$engine" begin-checkpoint --task-id "$task" --checkpoint 02 > begin-02.out

    set +e
    "$engine" with-commit-lock --task-id "$task" -- bash -c '
      echo drift > b.txt
      git add b.txt
      git commit -q -m "cp01 touches peer file"
      echo own > a.txt
      git add a.txt
      git commit -q -m "cp01 touches own file after drift"
      "$0" end-iteration --task-id "$1" --checkpoint 01
    ' "$engine" "$task" > drift.out 2> drift.err
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || {
      echo "expected drift path to exit non-zero" >&2
      exit 1
    }
    assert_contains drift.out "DRIFT_DETECTED"
    assert_contains drift.out "OFFENDING_PATH=b.txt"
    assert_contains drift.out "PEER_CHECKPOINT=02"
    event=".harness/$task/checkpoints/01/iter-1/drift-event.md"
    assert_contains "$event" "offending_path: b.txt"
    assert_contains "$event" "offending_checkpoint: 01"
    assert_contains "$event" "peer_checkpoint: 02"

    mkdir -p ".harness/$task/checkpoints/01/iter-1/evidence"
    echo "summary" > ".harness/$task/checkpoints/01/iter-1/output-summary.md"
    printf -- "---\nverdict: PASS\n---\n" > ".harness/$task/checkpoints/01/iter-1/evaluation.md"
    printf '%s\n' "11111111-1111-4111-8111-111111111111" > ".harness/$task/checkpoints/01/iter-1/evaluator-session-id.txt"
    if "$engine" pass-checkpoint --task-id "$task" --checkpoint 01 > pass-drift.out 2> pass-drift.err; then
      echo "pass-checkpoint accepted an unresolved drift event" >&2
      exit 1
    fi
    assert_contains pass-drift.err "unresolved cohort drift"

    "$engine" with-commit-lock --task-id "$task" -- bash -c '
      echo clean-retry > a.txt
      git add a.txt
      git commit -q -m "cp01 clean retry touches own file"
      "$0" end-iteration --task-id "$1" --checkpoint 01
    ' "$engine" "$task" > clean-retry.out
    assert_contains clean-retry.out "END_ITERATION_OK"
    [[ -f ".harness/$task/checkpoints/01/iter-1/drift-event.md" ]] || {
      echo "expected iter-1 drift-event.md to remain as evidence" >&2
      exit 1
    }
    [[ ! -f ".harness/$task/checkpoints/01/iter-2/drift-event.md" ]] || {
      echo "clean retry unexpectedly wrote drift-event.md" >&2
      exit 1
    }
    mkdir -p ".harness/$task/checkpoints/01/iter-2/evidence"
    echo "summary" > ".harness/$task/checkpoints/01/iter-2/output-summary.md"
    printf -- "---\nverdict: PASS\n---\n" > ".harness/$task/checkpoints/01/iter-2/evaluation.md"
    printf '%s\n' "22222222-2222-4222-8222-222222222222" > ".harness/$task/checkpoints/01/iter-2/evaluator-session-id.txt"
    "$engine" pass-checkpoint --task-id "$task" --checkpoint 01 > pass-clean-retry.out
    assert_contains pass-clean-retry.out "PASS_CHECKPOINT_OK"

    "$engine" with-commit-lock --task-id "$task" -- bash -c '
      echo peer-owned > b.txt
      git add b.txt
      git commit -q -m "cp02 touches own file"
      "$0" end-iteration --task-id "$1" --checkpoint 02
    ' "$engine" "$task" > peer.out
    assert_contains peer.out "END_ITERATION_OK"
    assert_not_contains peer.out "DRIFT_DETECTED"
  )
}

assert_serial_checkpoint_never_fails_drift_path() {
  local task="drift-serial"
  local repo="$tmpdir/serial"
  setup_repo "$repo" "$task"
  write_serial_spec "$repo" "$task"
  (
    cd "$repo"
    "$engine" init --task-id "$task" > init.out
    "$engine" begin-checkpoint --task-id "$task" --checkpoint 01 > begin-01.out
    echo serial > b.txt
    git add b.txt
    git commit -q -m "serial touches peer-looking file"
    "$engine" end-iteration --task-id "$task" --checkpoint 01 > serial.out
    assert_contains serial.out "END_ITERATION_OK"
    assert_not_contains serial.out "DRIFT_DETECTED"
    [[ ! -f ".harness/$task/checkpoints/01/iter-1/drift-event.md" ]] || {
      echo "serial checkpoint unexpectedly wrote drift-event.md" >&2
      exit 1
    }
  )
}

assert_cohort_peer_file_fails_iteration
assert_serial_checkpoint_never_fails_drift_path

echo "engine drift fail mode test passed"
