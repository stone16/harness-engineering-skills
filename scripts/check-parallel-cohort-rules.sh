#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file" || {
    echo "parallel-cohort mirror drift: $file is missing '$needle'" >&2
    exit 1
  }
}

surfaces=(
  "plugins/harness-engineering-skills/skills/harness/references/protocol-quick-ref.md"
  "plugins/harness-engineering-skills/skills/harness/references/checkpoint-definition.md"
  "plugins/harness-engineering-skills/skills/harness/scripts/harness-engine.sh"
  "plugins/harness-engineering-skills/agents/harness-spec-evaluator.md"
)

tokens=(
  "parallel_group"
  "BEGIN_COHORT_OK"
  "PASS_COHORT_OK"
  "commit_lock_timeout_seconds"
)

cd "$repo_root"

for surface in "${surfaces[@]}"; do
  [[ -f "$surface" ]] || {
    echo "parallel-cohort mirror drift: missing surface $surface" >&2
    exit 1
  }
  for token in "${tokens[@]}"; do
    assert_contains "$surface" "$token"
  done
done

echo "parallel-cohort rules check passed"
