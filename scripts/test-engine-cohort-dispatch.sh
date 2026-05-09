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
    git add README.md
    git commit -q -m "initial"
    git push -q -u origin main
    mkdir -p ".harness/$task"
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
  )
}

write_spec_cycle() {
  local repo="$1"
  local task="$2"
  cat > "$repo/.harness/$task/spec.md" <<'SPEC'
---
task_id: cohort-cycle
title: cohort cycle fixture
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
  - a.sh
- Effort estimate: S

### Checkpoint 02: second

- Scope: second
- Depends on: CP01
- Type: infrastructure
- parallel_group: A
- Acceptance criteria:
  - [ ] second
- Files of interest:
  - b.sh
- Effort estimate: S
SPEC
}

write_spec_overlap() {
  local repo="$1"
  local task="$2"
  local first="$3"
  local second="$4"
  cat > "$repo/.harness/$task/spec.md" <<SPEC
---
task_id: cohort-overlap
title: cohort overlap fixture
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
  - ${first}
- Effort estimate: S

### Checkpoint 02: second

- Scope: second
- Depends on: none
- Type: infrastructure
- parallel_group: A
- Acceptance criteria:
  - [ ] second
- Files of interest:
  - ${second}
- Effort estimate: S
SPEC
}

write_spec_disjoint() {
  local repo="$1"
  local task="$2"
  cat > "$repo/.harness/$task/spec.md" <<'SPEC'
---
task_id: cohort-disjoint
title: cohort disjoint fixture
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
  - a.sh
- Effort estimate: S

### Checkpoint 02: second

- Scope: second
- Depends on: none
- Type: infrastructure
- parallel_group: A
- Acceptance criteria:
  - [ ] second
- Files of interest:
  - b.sh
- Effort estimate: S
SPEC
}

write_spec_serial() {
  local repo="$1"
  local task="$2"
  cat > "$repo/.harness/$task/spec.md" <<'SPEC'
---
task_id: cohort-serial
title: cohort serial fixture
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
  - a.sh
- Effort estimate: S

### Checkpoint 02: second

- Scope: second
- Depends on: CP01
- Type: infrastructure
- Acceptance criteria:
  - [ ] second
- Files of interest:
  - b.sh
- Effort estimate: S
SPEC
}

assert_cohort_rejected_with_cycle() {
  local task="cohort-cycle"
  local repo="$tmpdir/cycle"
  setup_repo "$repo" "$task"
  write_spec_cycle "$repo" "$task"
  (
    cd "$repo"
    if "$engine" begin-cohort --task-id "$task" --group A >out.txt 2>err.txt; then
      echo "begin-cohort accepted an internal Depends on edge" >&2
      exit 1
    fi
    assert_contains err.txt "Error: cohort A members CP01 and CP02 have Depends on edge; same-group members must be independent"
    assert_contains err.txt ".harness/$task/spec.md"
  )
}

assert_cohort_rejected_with_overlap() {
  local task="cohort-overlap-basic"
  local repo="$tmpdir/overlap-basic"
  setup_repo "$repo" "$task"
  write_spec_overlap "$repo" "$task" "a.sh, b.sh" "b.sh, c.sh"
  (
    cd "$repo"
    if "$engine" begin-cohort --task-id "$task" --group A >out.txt 2>err.txt; then
      echo "begin-cohort accepted overlapping Files of interest" >&2
      exit 1
    fi
    assert_contains err.txt "overlapping Files of interest path b.sh"
    assert_contains err.txt "CP01"
    assert_contains err.txt "CP02"
  )

  task="cohort-overlap-dot"
  repo="$tmpdir/overlap-dot"
  setup_repo "$repo" "$task"
  write_spec_overlap "$repo" "$task" "./a.sh" "a.sh"
  (
    cd "$repo"
    if "$engine" begin-cohort --task-id "$task" --group A >out.txt 2>err.txt; then
      echo "begin-cohort accepted ./ path overlap" >&2
      exit 1
    fi
    assert_contains err.txt "overlapping Files of interest path a.sh"
  )

  task="cohort-overlap-new"
  repo="$tmpdir/overlap-new"
  setup_repo "$repo" "$task"
  write_spec_overlap "$repo" "$task" "scripts/foo.sh (new)" "scripts/foo.sh"
  (
    cd "$repo"
    if "$engine" begin-cohort --task-id "$task" --group A >out.txt 2>err.txt; then
      echo "begin-cohort accepted (new) path overlap" >&2
      exit 1
    fi
    assert_contains err.txt "overlapping Files of interest path scripts/foo.sh"
  )
}

assert_cohort_accepted_disjoint() {
  local task="cohort-disjoint"
  local repo="$tmpdir/disjoint"
  setup_repo "$repo" "$task"
  write_spec_disjoint "$repo" "$task"
  (
    cd "$repo"
    "$engine" begin-cohort --task-id "$task" --group A >begin.out
    assert_contains begin.out "BEGIN_COHORT_OK"
    assert_contains begin.out "GROUP=A"
    python3 - "$task" <<'PY'
import json
import pathlib
import sys

task = sys.argv[1]
state = json.loads(pathlib.Path(f".harness/{task}/git-state.json").read_text())
assert state["cohorts"]["A"]["members"] == ["01", "02"], state
assert state["cohorts"]["A"]["status"] == "pending", state
assert state["cohorts"]["A"]["baseline_sha"], state
assert state["checkpoints"]["01"]["cohort"] == "A", state
assert state["checkpoints"]["02"]["cohort"] == "A", state
PY
    python3 - "$task" <<'PY'
import json
import pathlib
import sys

task = sys.argv[1]
path = pathlib.Path(f".harness/{task}/git-state.json")
state = json.loads(path.read_text())
for cp in ("01", "02"):
    state["checkpoints"].setdefault(cp, {})["status"] = "passed"
    state["checkpoints"][cp]["final_sha"] = "test-final-sha"
path.write_text(json.dumps(state, indent=2) + "\n")
PY
    "$engine" pass-cohort --task-id "$task" --group A >pass.out
    assert_contains pass.out "PASS_COHORT_OK"
    python3 - "$task" <<'PY'
import json
import pathlib
import sys

task = sys.argv[1]
state = json.loads(pathlib.Path(f".harness/{task}/git-state.json").read_text())
assert state["cohorts"]["A"]["status"] == "passed", state
PY
  )
}

assert_serial_spec_uses_single_member_cohorts() {
  local task="cohort-serial"
  local repo="$tmpdir/serial"
  setup_repo "$repo" "$task"
  write_spec_serial "$repo" "$task"
  (
    cd "$repo"
    "$engine" begin-cohort --task-id "$task" --group 01 >begin-01.out
    "$engine" begin-cohort --task-id "$task" --group 02 >begin-02.out
    assert_contains begin-01.out "BEGIN_COHORT_OK"
    assert_contains begin-02.out "BEGIN_COHORT_OK"
    python3 - "$task" <<'PY'
import json
import pathlib
import sys

task = sys.argv[1]
state = json.loads(pathlib.Path(f".harness/{task}/git-state.json").read_text())
assert state["cohorts"]["01"]["members"] == ["01"], state
assert state["cohorts"]["02"]["members"] == ["02"], state
assert state["checkpoints"]["01"]["cohort"] == "01", state
assert state["checkpoints"]["02"]["cohort"] == "02", state
PY
  )
}

assert_cohort_rejected_with_cycle
assert_cohort_rejected_with_overlap
assert_cohort_accepted_disjoint
assert_serial_spec_uses_single_member_cohorts

echo "engine cohort dispatch test passed"
