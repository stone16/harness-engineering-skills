#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spec_evaluator="$repo_root/plugins/harness-engineering-skills/agents/harness-spec-evaluator.md"

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || {
    echo "missing expected text in $file: $expected" >&2
    exit 1
  }
}

assert_contains "$spec_evaluator" "parallel_group_safety"
assert_contains "$spec_evaluator" "Files of interest completeness audit"
assert_contains "$spec_evaluator" "Type compatibility audit"
assert_contains "$spec_evaluator" "parallel_group canonical shape audit"
assert_contains "$spec_evaluator" "skipping paths inside fenced code blocks and inline backticked spans"
assert_contains "$spec_evaluator" "severity: warning"
assert_contains "$spec_evaluator" "suggested_fix: extend Files of interest to include any prose-mentioned paths, split the cohort along the Type boundary, or normalize the parallel_group value to a single uppercase letter"

echo "spec-evaluator parallel-group safety test passed"
