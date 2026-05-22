#!/usr/bin/env bash
set -euo pipefail

# test-extract-markdown-verdict-parse-error.sh — Verify that
# extract_markdown_verdict in harness-engine.sh refuses to read a verdict
# out of a parse-error artifact, even when the embedded raw agent output
# contains a `verdict: PASS` line.
#
# Regression for the verdict-leak class identified in PR #47 review:
# normalize_claude_artifact.py wraps malformed agent output (e.g.
# `---\nverdict: PASS\n` with no closing fence) into a parse-error
# artifact that preserves the raw bytes for retro. Without the
# frontmatter short-circuit added to extract_markdown_verdict, the
# extractor's `(?im)^\s*verdict:\s*PASS` pattern would match the indented
# embedded line and silently pass the gate.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="$repo_root/plugins/harness-engineering-skills/skills/harness/scripts/harness-engine.sh"
normalizer="$repo_root/plugins/harness-engineering-skills/skills/harness/scripts/normalize_claude_artifact.py"

if [[ ! -f "$engine" || ! -f "$normalizer" ]]; then
  echo "Error: harness-engine.sh or normalizer not found" >&2
  exit 1
fi

# The engine script unconditionally dispatches a CLI command at the bottom,
# so we cannot `source` it directly. Pull just the function body out via
# sed and eval it into this shell. If the function signature in
# harness-engine.sh changes the eval will fail loudly, which is what we
# want — this test must stay locked to the production code.
fn_src=$(sed -n '/^extract_markdown_verdict()/,/^}$/p' "$engine")
if [[ -z "$fn_src" ]]; then
  echo "Error: could not extract extract_markdown_verdict() from $engine" >&2
  exit 1
fi
eval "$fn_src"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/harness-verdict-parse-error-XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

scenario=1
echo "[$scenario] parse-error artifact with embedded 'verdict: PASS' yields NO verdict"
raw="$workdir/raw.txt"
artifact="$workdir/parse-err.md"
# Agent output that violates the contract: opener present, NO closing '---'.
printf -- '---\nverdict: PASS\nnotes: missing closing fence\n' > "$raw"
python3 "$normalizer" \
  --agent harness-evaluator \
  --result-file "$raw" \
  --output-file "$artifact" 2>/dev/null \
  || true  # exit 2 is expected (malformed input)

# Sanity: artifact must exist, be a parse-error, AND still carry the raw
# 'verdict: PASS' line for retro evidence.
if [[ ! -f "$artifact" ]]; then
  echo "scenario $scenario: normalizer did not write artifact at $artifact" >&2
  exit 1
fi
grep -Fq "result: parse-error" "$artifact" || {
  echo "scenario $scenario: artifact is missing 'result: parse-error' frontmatter" >&2
  cat "$artifact" >&2
  exit 1
}
grep -Fq "verdict: PASS" "$artifact" || {
  echo "scenario $scenario: artifact should preserve raw 'verdict: PASS' line as retro evidence" >&2
  cat "$artifact" >&2
  exit 1
}

verdict=$(extract_markdown_verdict "$artifact")
if [[ -n "$verdict" ]]; then
  echo "scenario $scenario: parse-error artifact must NOT yield a verdict, got '$verdict'" >&2
  cat "$artifact" >&2
  exit 1
fi
((scenario++))

echo "[$scenario] well-formed artifact still extracts the verdict"
good="$workdir/good.md"
cat > "$good" <<'EOF'
---
verdict: PASS
score: 9
---

Body.
EOF
verdict=$(extract_markdown_verdict "$good")
if [[ "$verdict" != "PASS" ]]; then
  echo "scenario $scenario: expected verdict PASS, got '$verdict'" >&2
  exit 1
fi
((scenario++))

echo "[$scenario] artifact with no frontmatter still allows verdict extraction (back-compat)"
loose="$workdir/loose.md"
cat > "$loose" <<'EOF'
Some preamble.

verdict: FAIL

More text.
EOF
verdict=$(extract_markdown_verdict "$loose")
if [[ "$verdict" != "FAIL" ]]; then
  echo "scenario $scenario: expected verdict FAIL, got '$verdict'" >&2
  exit 1
fi

echo "extract_markdown_verdict parse-error regression test passed (${scenario} scenarios)"
