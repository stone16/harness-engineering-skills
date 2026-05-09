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
task_id: cohort-e2e
title: cohort end-to-end fixture
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

write_pass_artifacts() {
  local task="$1"
  local cp="$2"
  local session_id="$3"
  local iter_dir=".harness/$task/checkpoints/$cp/iter-1"
  mkdir -p "$iter_dir/evidence"
  cat > "$iter_dir/output-summary.md" <<SUMMARY
# Checkpoint $cp Output

Implemented fixture checkpoint $cp.
SUMMARY
  cat > "$iter_dir/evaluation.md" <<EVAL
---
verdict: PASS
---

# Evaluation

Fixture evaluator pass for checkpoint $cp.
EVAL
  printf '%s\n' "$session_id" > "$iter_dir/evaluator-session-id.txt"
}

assert_full_cohort_lifecycle() {
  local task="cohort-e2e"
  local repo="$tmpdir/e2e"
  setup_repo "$repo" "$task"
  write_spec "$repo" "$task"
  (
    cd "$repo"
    "$engine" init --task-id "$task" > init.out
    "$engine" begin-cohort --task-id "$task" --group A > begin-cohort.out
    assert_contains begin-cohort.out "BEGIN_COHORT_OK"

    "$engine" begin-checkpoint --task-id "$task" --checkpoint 01 > begin-01.out
    "$engine" begin-checkpoint --task-id "$task" --checkpoint 02 > begin-02.out

    "$engine" with-commit-lock --task-id "$task" -- bash -c '
      echo generator-01 > a.txt
      git add a.txt
      git commit -q -m "generator cp01"
      "$0" end-iteration --task-id "$1" --checkpoint 01
    ' "$engine" "$task" > end-01.out
    assert_contains end-01.out "END_ITERATION_OK"

    "$engine" with-commit-lock --task-id "$task" -- bash -c '
      echo generator-02 > b.txt
      git add b.txt
      git commit -q -m "generator cp02"
      "$0" end-iteration --task-id "$1" --checkpoint 02
    ' "$engine" "$task" > end-02.out
    assert_contains end-02.out "END_ITERATION_OK"
    [[ -f ".harness/$task/.commit.lock" ]] || {
      echo "expected end-iteration to acquire the commit lock" >&2
      exit 1
    }

    write_pass_artifacts "$task" "01" "11111111-1111-4111-8111-111111111111"
    write_pass_artifacts "$task" "02" "22222222-2222-4222-8222-222222222222"
    "$engine" pass-checkpoint --task-id "$task" --checkpoint 01 > pass-01.out
    "$engine" pass-checkpoint --task-id "$task" --checkpoint 02 > pass-02.out
    "$engine" pass-cohort --task-id "$task" --group A > pass-cohort.out
    assert_contains pass-cohort.out "PASS_COHORT_OK"

    python3 - "$task" <<'PY'
import json
import pathlib
import sys

task = sys.argv[1]
state = json.loads(pathlib.Path(f".harness/{task}/git-state.json").read_text())
assert state["cohorts"]["A"]["status"] == "passed", state
assert state["cohorts"]["A"]["members"] == ["01", "02"], state
for cp in ("01", "02"):
    assert state["checkpoints"][cp]["cohort"] == "A", state
    assert state["checkpoints"][cp].get("final_sha"), state
    assert state["checkpoints"][cp].get("evaluator_session_id"), state
PY
  )
}

assert_full_cohort_lifecycle

echo "engine cohort end-to-end test passed"
