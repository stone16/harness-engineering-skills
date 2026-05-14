#!/usr/bin/env bash
set -euo pipefail

# test-claude-artifact-frontmatter.sh — Cover the normalize/validate contract
# in plugins/.../scripts/normalize_claude_artifact.py.
#
# Scenarios:
#   1. Already-valid raw YAML frontmatter passes through unchanged.
#   2. ```yaml fenced artifact is unwrapped to raw YAML.
#   3. Plain ``` fenced artifact is unwrapped.
#   4. "- ---" list-prefixed first line is de-prefixed.
#   5. Leading blank lines are stripped.
#   6. Missing closing "---" fails loud (exit 2) AND writes parse-error YAML.
#   7. Empty result fails loud.
#   8. When result is malformed but existing artifact has a valid
#      opener-plus-closer, preserve the existing artifact and exit 0.
#   9. When result is malformed AND existing artifact has only an opener (no
#      closing '---'), do NOT preserve — fall through to parse-error.
#  10. Whitespace-only blank lines after a code fence are stripped.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_root/plugins/harness-engineering-skills/skills/harness/scripts/normalize_claude_artifact.py"

if [[ ! -f "$helper" ]]; then
  echo "Error: helper not found at $helper" >&2
  exit 1
fi

# shellcheck source=lib/test-helpers.sh
source "$repo_root/scripts/lib/test-helpers.sh"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/harness-claude-artifact-XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

run_helper() {
  local result_file="$1"
  local output_file="$2"
  local existing_file="${3:-}"
  local args=(--agent test-agent --result-file "$result_file" --output-file "$output_file")
  if [[ -n "$existing_file" ]]; then
    args+=(--existing-file "$existing_file")
  fi
  python3 "$helper" "${args[@]}"
}

scenario=1
echo "[$scenario] valid raw frontmatter passes through unchanged"
in1="$workdir/in1.txt"
out1="$workdir/out1.txt"
cat > "$in1" <<'EOF'
---
verdict: pass
score: 9
---

Body text here.
EOF
run_helper "$in1" "$out1"
assert_contains "$out1" "verdict: pass"
assert_contains "$out1" "Body text here."
diff_count=$(diff "$in1" "$out1" | wc -l | tr -d ' ')
if [[ "$diff_count" != "0" ]]; then
  echo "scenario $scenario expected identical content; diff:" >&2
  diff "$in1" "$out1" >&2 || true
  exit 1
fi
((scenario++))

echo "[$scenario] backtick-yaml fence is unwrapped"
in2="$workdir/in2.txt"
out2="$workdir/out2.txt"
cat > "$in2" <<'EOF'
```yaml
---
verdict: pass
---

Body
```
EOF
run_helper "$in2" "$out2"
assert_contains "$out2" "verdict: pass"
first_line=$(head -n 1 "$out2")
if [[ "$first_line" != "---" ]]; then
  echo "scenario $scenario: first line of normalized output is not '---' (got '$first_line')" >&2
  cat "$out2" >&2
  exit 1
fi
assert_not_contains "$out2" '```yaml'
assert_not_contains "$out2" '```'
((scenario++))

echo "[$scenario] plain backtick fence is unwrapped"
in3="$workdir/in3.txt"
out3="$workdir/out3.txt"
cat > "$in3" <<'EOF'
```
---
verdict: review
---

Notes
```
EOF
run_helper "$in3" "$out3"
first_line=$(head -n 1 "$out3")
if [[ "$first_line" != "---" ]]; then
  echo "scenario $scenario: first line not '---' (got '$first_line')" >&2
  exit 1
fi
assert_contains "$out3" "verdict: review"
((scenario++))

echo "[$scenario] '- ---' list-prefix first line is de-prefixed"
in4="$workdir/in4.txt"
out4="$workdir/out4.txt"
cat > "$in4" <<'EOF'
- ---
verdict: fail
---
EOF
run_helper "$in4" "$out4"
first_line=$(head -n 1 "$out4")
if [[ "$first_line" != "---" ]]; then
  echo "scenario $scenario: first line not '---' (got '$first_line')" >&2
  cat "$out4" >&2
  exit 1
fi
assert_contains "$out4" "verdict: fail"
((scenario++))

echo "[$scenario] leading blank lines are stripped"
in5="$workdir/in5.txt"
out5="$workdir/out5.txt"
cat > "$in5" <<'EOF'



---
verdict: pass
---
EOF
run_helper "$in5" "$out5"
first_line=$(head -n 1 "$out5")
if [[ "$first_line" != "---" ]]; then
  echo "scenario $scenario: first line not '---' (got '$first_line')" >&2
  exit 1
fi
((scenario++))

echo "[$scenario] missing closing '---' fails loud with parse-error artifact"
in6="$workdir/in6.txt"
out6="$workdir/out6.txt"
cat > "$in6" <<'EOF'
---
verdict: pass
notes: missing closing fence on purpose
EOF
set +e
run_helper "$in6" "$out6" 2> "$workdir/err6.txt"
rc=$?
set -e
if [[ "$rc" -ne 2 ]]; then
  echo "scenario $scenario: expected exit code 2 (parse-error), got $rc" >&2
  exit 1
fi
assert_contains "$out6" "result: parse-error"
assert_contains "$out6" "agent: test-agent"
assert_contains "$out6" "no closing '---' line found"
assert_contains "$workdir/err6.txt" "malformed artifact"
((scenario++))

echo "[$scenario] empty input fails loud"
in7="$workdir/in7.txt"
out7="$workdir/out7.txt"
: > "$in7"
set +e
run_helper "$in7" "$out7" 2> "$workdir/err7.txt"
rc=$?
set -e
if [[ "$rc" -ne 2 ]]; then
  echo "scenario $scenario: expected exit code 2 for empty input, got $rc" >&2
  exit 1
fi
assert_contains "$out7" "result: parse-error"
((scenario++))

echo "[$scenario] malformed result + valid existing artifact -> preserve existing"
in8="$workdir/in8.txt"
out8="$workdir/out8.txt"
existing8="$workdir/existing8.txt"
cat > "$existing8" <<'EOF'
---
verdict: pass
written_by: agent_directly
---

Detailed evaluation body.
EOF
cat > "$in8" <<'EOF'
Here is a prose summary instead of frontmatter.
EOF
set +e
run_helper "$in8" "$out8" "$existing8" 2> "$workdir/err8.txt"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "scenario $scenario: expected exit code 0 (preserved existing), got $rc" >&2
  cat "$workdir/err8.txt" >&2
  exit 1
fi
# Output file should not have been touched / created by the helper in preserve mode.
if [[ -f "$out8" ]]; then
  echo "scenario $scenario: expected output file to NOT be written when preserving existing" >&2
  exit 1
fi
assert_contains "$workdir/err8.txt" "preserving existing"
((scenario++))

echo "[$scenario] malformed result + existing artifact missing closing '---' -> parse-error (NOT preserved)"
in9="$workdir/in9.txt"
out9="$workdir/out9.txt"
existing9="$workdir/existing9.txt"
# Existing artifact has the opener but NO closing '---' — exactly the stale-PASS
# regression class Hao called out: the engine could otherwise consume an
# evaluator-invalid file because the previous _has_valid_opening check accepted
# any first line of '---'.
cat > "$existing9" <<'EOF'
---
verdict: PASS
notes: stale partial write — missing closing fence
EOF
cat > "$in9" <<'EOF'
Some prose summary instead of frontmatter.
EOF
set +e
run_helper "$in9" "$out9" "$existing9" 2> "$workdir/err9.txt"
rc=$?
set -e
if [[ "$rc" -ne 2 ]]; then
  echo "scenario $scenario: expected exit code 2 (parse-error, NOT preserve stale partial), got $rc" >&2
  cat "$workdir/err9.txt" >&2
  exit 1
fi
assert_contains "$out9" "result: parse-error"
assert_contains "$out9" "agent: test-agent"
if grep -q "preserving existing" "$workdir/err9.txt"; then
  echo "scenario $scenario: stderr unexpectedly mentions preservation; existing must not be preserved when malformed" >&2
  cat "$workdir/err9.txt" >&2
  exit 1
fi
((scenario++))

echo "[$scenario] whitespace-only blank lines after code fence are stripped"
in10="$workdir/in10.txt"
out10="$workdir/out10.txt"
# Fenced artifact where, after the fence, the next line contains only spaces
# (not a bare newline). `lstrip("\n")` did not handle this; the regex strip
# must catch it.
printf '```yaml\n   \n---\nverdict: pass\n---\n```\n' > "$in10"
run_helper "$in10" "$out10"
first_line=$(head -n 1 "$out10")
if [[ "$first_line" != "---" ]]; then
  echo "scenario $scenario: first line not '---' after fence + whitespace strip (got '$first_line')" >&2
  cat "$out10" >&2
  exit 1
fi
assert_contains "$out10" "verdict: pass"

echo "claude artifact frontmatter normalization test passed (${scenario} scenarios)"
