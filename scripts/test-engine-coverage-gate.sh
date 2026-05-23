#!/usr/bin/env bash
set -euo pipefail

# Regression test for issue #35: pass-full-verify coverage gate must
# (a) use anchored `^- Type:` parsing instead of broad-grep against spec prose,
# (b) handle null / N/A / missing / non-numeric coverage_percent without
#     crashing bash arithmetic, and
# (c) exempt frontend-only tasks from the gate even when prose mentions
#     "backend" or "infrastructure".

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="$repo_root/plugins/harness-engineering-skills/skills/harness/scripts/harness-engine.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

scenarios_run=0

write_spec() {
  local task_dir="$1"
  local checkpoints_block="$2"
  cat > "$task_dir/spec.md" <<SPEC
---
task_id: cov-gate-test
title: coverage gate fixture
version: 1
status: approved
branch: test
created: 2026-05-23
updated: 2026-05-23
---

## Goal

$checkpoints_block
SPEC
}

write_report() {
  local fv_dir="$1"
  local coverage_line="$2"
  mkdir -p "$fv_dir/iter-1"
  cat > "$fv_dir/iter-1/verification-report.md" <<REPORT
---
task_id: cov-gate-test
iteration: 1
verdict: PASS
hard_failures: 0
soft_warnings: 0
$coverage_line
---

# Verification Report
REPORT
}

setup_full_verify_state() {
  local repo="$1"
  local task="cov-gate-test"
  git init -q -b main "$repo"
  (
    cd "$repo"
    git config user.email "test@example.com"
    git config user.name "Coverage Gate Test"
    echo root > README.md
    git add README.md
    git commit -q -m "initial"
  )
  local task_dir="$repo/.harness/$task"
  mkdir -p "$task_dir/full-verify"
  local baseline
  baseline="$(cd "$repo" && git rev-parse HEAD)"
  cat > "$task_dir/git-state.json" <<JSON
{
  "task_id": "$task",
  "task_start_sha": "$baseline",
  "phase": "full-verify",
  "checkpoints": {},
  "e2e_baseline_sha": "",
  "e2e_final_sha": "",
  "review_loop_status": "",
  "review_loop_session_id": "",
  "review_loop_summary_file": "",
  "review_loop_rounds_file": "",
  "full_verify_baseline_sha": "$baseline",
  "full_verify_final_sha": "",
  "full_verify_status": "",
  "pr_url": ""
}
JSON
  echo "$task_dir"
}

run_pass_full_verify() {
  local repo="$1"
  (cd "$repo" && "$engine" pass-full-verify --task-id cov-gate-test 2>&1; echo "EXIT=$?")
}

scenario() {
  local desc="$1"
  scenarios_run=$((scenarios_run + 1))
  printf '[%d] %s\n' "$scenarios_run" "$desc"
}

assert_phase_blocked_with() {
  local out="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" <<<"$out"; then
    echo "FAIL: expected PHASE_BLOCKED reason to contain: $needle" >&2
    echo "actual:" >&2
    echo "$out" >&2
    exit 1
  fi
  grep -q '^EXIT=1$' <<<"$out" || {
    echo "FAIL: expected exit 1 (PHASE_BLOCKED), got:" >&2
    echo "$out" >&2
    exit 1
  }
}

assert_passed() {
  local out="$1"
  grep -q '^EXIT=0$' <<<"$out" || {
    echo "FAIL: expected exit 0 (PASS), got:" >&2
    echo "$out" >&2
    exit 1
  }
}

# ── Scenario 1: backend CP + null coverage → FAIL (regression for arithmetic crash) ──
scenario "backend CP + coverage_percent: null → PHASE_BLOCKED with explicit reason (no crash)"
repo="$tmpdir/s1"
task_dir="$(setup_full_verify_state "$repo")"
write_spec "$task_dir" "
### Checkpoint 01: api
- Type: backend
- Scope: x
- Acceptance criteria: y
"
write_report "$task_dir/full-verify" "coverage_percent: null"
out="$(run_pass_full_verify "$repo")"
assert_phase_blocked_with "$out" "coverage_percent is 'null'"

# ── Scenario 2: backend CP + missing coverage_percent → FAIL ──
scenario "backend CP + missing coverage_percent → PHASE_BLOCKED"
repo="$tmpdir/s2"
task_dir="$(setup_full_verify_state "$repo")"
write_spec "$task_dir" "
### Checkpoint 01: api
- Type: backend
- Scope: x
- Acceptance criteria: y
"
write_report "$task_dir/full-verify" ""
out="$(run_pass_full_verify "$repo")"
assert_phase_blocked_with "$out" "coverage_percent is '<missing>'"

# ── Scenario 3: backend CP + non-numeric coverage → FAIL (no arithmetic crash) ──
scenario "backend CP + coverage_percent: abc → PHASE_BLOCKED for non-numeric"
repo="$tmpdir/s3"
task_dir="$(setup_full_verify_state "$repo")"
write_spec "$task_dir" "
### Checkpoint 01: api
- Type: backend
- Scope: x
- Acceptance criteria: y
"
write_report "$task_dir/full-verify" "coverage_percent: abc"
out="$(run_pass_full_verify "$repo")"
assert_phase_blocked_with "$out" "is not numeric"

# ── Scenario 4: frontend-only CP + null coverage → PASS (frontend-only exemption) ──
scenario "every CP is Type:frontend + coverage_percent: null → PASS (exemption)"
repo="$tmpdir/s4"
task_dir="$(setup_full_verify_state "$repo")"
write_spec "$task_dir" "
### Checkpoint 01: ui-button
- Type: frontend
- Scope: x
- Acceptance criteria: y

### Checkpoint 02: ui-nav
- Type: frontend
- Scope: x
- Acceptance criteria: y
"
write_report "$task_dir/full-verify" "coverage_percent: null"
out="$(run_pass_full_verify "$repo")"
assert_passed "$out"

# ── Scenario 5: frontend-only CP but prose mentions backend → PASS (anchored parsing) ──
# Regression for broad-grep false-positive: "preserve all existing backend wiring"
# previously tripped the gate because grep matched "Type" + "backend" across the line.
scenario "frontend-only CPs + prose mentions backend → PASS (anchored Type parsing)"
repo="$tmpdir/s5"
task_dir="$(setup_full_verify_state "$repo")"
write_spec "$task_dir" "
Note: the Type-based dispatch should preserve all existing backend wiring even after refactor.

### Checkpoint 01: ui
- Type: frontend
- Scope: x
- Acceptance criteria: y
"
write_report "$task_dir/full-verify" "coverage_percent: null"
out="$(run_pass_full_verify "$repo")"
assert_passed "$out"

# ── Scenario 6: backend CP + 87% coverage → PASS (happy path with threshold 85) ──
scenario "backend CP + coverage_percent: 87 → PASS (above default threshold 85)"
repo="$tmpdir/s6"
task_dir="$(setup_full_verify_state "$repo")"
write_spec "$task_dir" "
### Checkpoint 01: api
- Type: backend
- Scope: x
- Acceptance criteria: y
"
write_report "$task_dir/full-verify" "coverage_percent: 87"
out="$(run_pass_full_verify "$repo")"
assert_passed "$out"

# ── Scenario 7: backend CP + 70% coverage → FAIL (below threshold) ──
scenario "backend CP + coverage_percent: 70 → PHASE_BLOCKED below threshold"
repo="$tmpdir/s7"
task_dir="$(setup_full_verify_state "$repo")"
write_spec "$task_dir" "
### Checkpoint 01: api
- Type: backend
- Scope: x
- Acceptance criteria: y
"
write_report "$task_dir/full-verify" "coverage_percent: 70"
out="$(run_pass_full_verify "$repo")"
assert_phase_blocked_with "$out" "below threshold 85"

# ── Scenario 8: compat **Type** decorated form on backend CP → still detected ──
scenario "backend CP using compat decorated '- **Type**: backend' shape → gate still enforces"
repo="$tmpdir/s8"
task_dir="$(setup_full_verify_state "$repo")"
write_spec "$task_dir" "
### Checkpoint 01: api
- **Type**: backend
- Scope: x
- Acceptance criteria: y
"
write_report "$task_dir/full-verify" "coverage_percent: null"
out="$(run_pass_full_verify "$repo")"
assert_phase_blocked_with "$out" "coverage_percent is 'null'"

# ── Scenario 9: case-typo `- Type: Backend` + null coverage → FAIL (case-insensitive) ──
# Regression for codex-connector PR #52 review. Strict-lowercase regex would
# not match `Backend`, both backend_cp_count and frontend_cp_count would be 0,
# frontend_only would be false, and the gate's `if` would not fire. Combined
# with the `|| echo 0` multi-line bug, this silently skipped enforcement.
scenario "Type:Backend (capital B typo) + null coverage → PHASE_BLOCKED (case-insensitive)"
repo="$tmpdir/s9"
task_dir="$(setup_full_verify_state "$repo")"
write_spec "$task_dir" "
### Checkpoint 01: api
- Type: Backend
- Scope: x
- Acceptance criteria: y
"
write_report "$task_dir/full-verify" "coverage_percent: null"
out="$(run_pass_full_verify "$repo")"
assert_phase_blocked_with "$out" "coverage_percent is 'null'"

# ── Scenario 10: zero Type: lines must not trigger ((…)) syntax errors ──
# Regression for codex-connector PR #52: a spec with NO Type lines previously
# made backend_cp_count="0\n0" via grep+`|| echo 0`, which triggered a `((…))`
# syntax error AND silently treated the count as zero. After the fix the
# count is a clean 0 and arithmetic is safe.
scenario "spec with zero Type: lines does not leak ((…)) syntax errors to stderr"
repo="$tmpdir/s10"
task_dir="$(setup_full_verify_state "$repo")"
write_spec "$task_dir" "
### Checkpoint 01: api
- Scope: x
- Acceptance criteria: y
"
write_report "$task_dir/full-verify" "coverage_percent: null"
stderr_file="$tmpdir/s10.stderr"
(cd "$repo" && "$engine" pass-full-verify --task-id cov-gate-test 2>"$stderr_file" >/dev/null) || true
if grep -Fq 'syntax error in expression' "$stderr_file"; then
  echo "FAIL: bash arithmetic syntax error leaked to stderr — multi-line count regression?" >&2
  cat "$stderr_file" >&2
  exit 1
fi

echo "pass-full-verify coverage gate test passed ($scenarios_run scenarios)"
