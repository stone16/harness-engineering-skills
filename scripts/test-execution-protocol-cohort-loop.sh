#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
execution_protocol="$repo_root/plugins/harness-engineering-skills/skills/harness/references/execution-protocol.md"
planning_protocol="$repo_root/plugins/harness-engineering-skills/skills/harness/references/planning-protocol.md"

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || {
    echo "missing expected text in $file: $expected" >&2
    exit 1
  }
}

assert_contains "$execution_protocol" '8. **cohort partial-PASS escalation** — at least one cohort member exhausted `max_eval_rounds` while peers in the same cohort reached PASS; user must split the failing CP, supply hints + retry, or abort the cohort.'
assert_contains "$execution_protocol" "These eight scenarios are the only pause points."
assert_contains "$execution_protocol" "#### Cohort Execution Loop"
assert_contains "$execution_protocol" "\$ENGINE begin-cohort --task-id <id> --group <letter>"
assert_contains "$execution_protocol" "\$ENGINE begin-checkpoint --task-id <id> --checkpoint <NN>"
assert_contains "$execution_protocol" "parallel dispatch of Generators in a single Agent-tool batch in Claude Code"
assert_contains "$execution_protocol" '`&`-backgrounded `claude-agent-invoke.sh` calls in Codex'
assert_contains "$execution_protocol" 'the GNU-`timeout` precedent at `claude-agent-invoke.sh:88-104`'
assert_contains "$execution_protocol" '$ENGINE with-commit-lock --task-id <id> -- <command>'
assert_contains "$execution_protocol" 'If a member'\''s `end-iteration` emits `DRIFT_DETECTED`, forward'
assert_contains "$execution_protocol" "Run parallel Evaluators after all Generators finish"
assert_contains "$execution_protocol" 'all PASS → `$ENGINE pass-cohort --task-id <id> --group <letter>`'
assert_contains "$execution_protocol" "\$ENGINE escalate-checkpoint --task-id <id> --checkpoint <NN>"

assert_contains "$planning_protocol" 'During spec drafting, consider `parallel_group` cohort declarations for independent checkpoints and cite the `parallel_group_safety` Spec Evaluator check when grouping depends on complete Files of interest and compatible Type metadata.'

echo "execution protocol cohort loop test passed"
