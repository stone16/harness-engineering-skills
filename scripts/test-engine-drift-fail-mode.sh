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

assert_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -Fq -- "$needle" "$file"; then
    echo "unexpected text in $file: $needle" >&2
    exit 1
  fi
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

    echo drift > b.txt
    git add b.txt
    git commit -q -m "cp01 touches peer file"
    set +e
    "$engine" end-iteration --task-id "$task" --checkpoint 01 > drift.out 2> drift.err
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

    echo peer-owned > b.txt
    git add b.txt
    git commit -q -m "cp02 touches own file"
    "$engine" end-iteration --task-id "$task" --checkpoint 02 > peer.out
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
