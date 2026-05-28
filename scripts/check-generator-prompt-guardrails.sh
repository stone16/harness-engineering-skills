#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generator_prompt="$repo_root/plugins/harness-engineering-skills/agents/harness-generator.md"

if [[ ! -f "$generator_prompt" ]]; then
  echo "missing generator prompt: $generator_prompt" >&2
  exit 1
fi

assert_contains() {
  local needle="$1"
  grep -Fq -- "$needle" "$generator_prompt" || {
    echo "generator prompt is missing expected guardrail: $needle" >&2
    exit 1
  }
}

assert_contains "Never pass \`--no-verify\` or \`-n\` to \`git commit\`"
assert_contains "Pre-commit hooks are part of the verification surface"
assert_contains "do not bypass it"

echo "generator prompt guardrails check passed"
