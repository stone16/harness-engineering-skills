#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spec_evaluator="$repo_root/plugins/harness-engineering-skills/agents/harness-spec-evaluator.md"

# shellcheck source=lib/test-helpers.sh
source "$repo_root/scripts/lib/test-helpers.sh"

assert_contains "$spec_evaluator" "coverage criterion scope/dimension ambiguity"
assert_contains "$spec_evaluator" "omit lines/statements/functions/branches"
assert_contains "$spec_evaluator" "dimensions while sibling criteria include them"
assert_contains "$spec_evaluator" "scope to a function"
assert_contains "$spec_evaluator" "subset while sibling criteria scope to a whole file/package"
assert_contains "$spec_evaluator" "a file/module in a per-file >=N rule that is excluded from the binding"
assert_contains "$spec_evaluator" "Success Criteria coverage set"
assert_contains "$spec_evaluator" "gate, binding dimensions, and binding scope"
assert_contains "$spec_evaluator" "so checkpoint Evaluators do not resolve strict-vs-lenient coverage"
assert_contains "$spec_evaluator" "readings after implementation"

echo "spec-evaluator coverage-criteria ambiguity test passed"
