#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

protocol_ref="$repo_root/plugins/harness-engineering-skills/skills/harness/references/protocol-quick-ref.md"
checkpoint_ref="$repo_root/plugins/harness-engineering-skills/skills/harness/references/checkpoint-definition.md"

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || {
    echo "missing expected text in $file: $expected" >&2
    exit 1
  }
}

assert_contains "$protocol_ref" "- parallel_group: <letter>"
assert_contains "$protocol_ref" "a single uppercase letter (A-Z); checkpoints sharing the same letter form a cohort dispatched concurrently"
assert_contains "$protocol_ref" "Absence of the field means the checkpoint forms its own single-member cohort (today's serial behavior). No explicit serial sentinel form is recognized."
assert_contains "$protocol_ref" '"cohort": "<letter>"'
assert_contains "$protocol_ref" '"cohorts": {'
assert_contains "$protocol_ref" '"status": "pending | running | passed | partial-pass | aborted"'
assert_contains "$protocol_ref" "BEGIN_COHORT_OK"
assert_contains "$protocol_ref" "PASS_COHORT_OK"

assert_contains "$checkpoint_ref" "| parallel_group | No | Cohort letter (single uppercase A-Z); checkpoints with the same letter are dispatched concurrently. Absent = single-member cohort (serial). |"
assert_contains "$checkpoint_ref" "Checkpoints in the same \`parallel_group\` execute concurrently within a cohort; cohorts execute sequentially."
assert_contains "$checkpoint_ref" "A checkpoint may assume that all PASS members of every prior cohort are complete."
assert_contains "$checkpoint_ref" "Cohort order is determined by the lowest checkpoint number in each cohort."
assert_contains "$checkpoint_ref" "The engine rejects cohorts whose members declare \`Depends on\` edges among themselves."

echo "spec format parallel-group docs test passed"
