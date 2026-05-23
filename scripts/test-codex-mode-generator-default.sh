#!/usr/bin/env bash
set -euo pipefail

# Doc-drift detector for issue #34: codex-mode.md and SKILL.md must agree
# that the Generator role runs in a fresh sub-agent (Claude OR Codex) per
# checkpoint, with local main-session execution as the explicit fallback
# (not the default). Catches future regressions where a doc edit silently
# re-introduces "Codex implements the checkpoint locally" as the default
# Generator path.
#
# This is a small, focused assertion set — it does not parse markdown or
# attempt full semantic understanding. It looks for the specific phrases
# that encode the contract.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
codex_mode="$repo_root/plugins/harness-engineering-skills/skills/harness/references/codex-mode.md"
skill="$repo_root/plugins/harness-engineering-skills/skills/harness/SKILL.md"

assert_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file" || {
    echo "codex-mode/SKILL drift: $file is missing expected text: $needle" >&2
    exit 1
  }
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -Fq -- "$needle" "$file"; then
    echo "codex-mode/SKILL drift: $file contains forbidden text: $needle" >&2
    echo "(Removed by issue #34. If you really need to re-introduce, update this test too.)" >&2
    exit 1
  fi
}

# ── codex-mode.md asserts ──

# Generator sub-agent default is documented as the primary path.
assert_contains "$codex_mode" "Generator dispatch — sub-agent is the default"

# Fallback path is documented with the marker.
assert_contains "$codex_mode" "HARNESS_GENERATOR_MODE=subagent"
assert_contains "$codex_mode" "HARNESS_GENERATOR_MODE=main-session-fallback"
assert_contains "$codex_mode" "generator-session-id.txt"

# The pre-#34 phrasing that established "local by default" is gone.
assert_not_contains "$codex_mode" "Codex implements the checkpoint locally in the current session."
assert_not_contains "$codex_mode" "Do not require Codex subagents. Use them only if the user explicitly asked for delegation."

# ── SKILL.md asserts ──

# Architecture line treats Generator as a sub-agent role for both hosts.
assert_contains "$skill" "Generator          → sub-agent (Claude or Codex)"

# Anti-drift "fresh Generator + Evaluator per checkpoint" is preserved.
assert_contains "$skill" "Fresh Generator + Evaluator per checkpoint"

# The pre-#34 phrasing "(or local in Codex)" is gone — would re-introduce
# the contradiction between SKILL.md's anti-drift line and codex-mode.md.
assert_not_contains "$skill" "(or local in Codex)"

echo "codex-mode + SKILL generator-default consistency test passed"
