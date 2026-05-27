#!/usr/bin/env bash
set -euo pipefail

# test-claude-agent-invoke-e2e.sh — End-to-end check of the malformed-artifact
# fail-loud path through claude-agent-invoke.sh. Uses a stubbed `claude` CLI on
# PATH that emits a pre-recorded stream-json log, so the test does not require
# a real Claude session.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/plugins/harness-engineering-skills/skills/harness/scripts/claude-agent-invoke.sh"

if [[ ! -f "$script" ]]; then
  echo "Error: $script not found" >&2
  exit 1
fi

# shellcheck source=lib/test-helpers.sh
source "$repo_root/scripts/lib/test-helpers.sh"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/harness-claude-e2e-XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

# Stub `claude` CLI: echo the contents of a fixture log file specified via
# HARNESS_TEST_STUB_LOG. This bypasses the real Claude process while preserving
# the script's input/output contract.
mkdir -p "$workdir/bin"
cat > "$workdir/bin/claude" <<'STUB'
#!/usr/bin/env bash
# Drain stdin so callers do not stall waiting on the prompt.
cat > /dev/null
if [[ -z "${HARNESS_TEST_STUB_LOG:-}" || ! -f "$HARNESS_TEST_STUB_LOG" ]]; then
  echo "stub claude: HARNESS_TEST_STUB_LOG not set or not a file" >&2
  exit 99
fi
cat "$HARNESS_TEST_STUB_LOG"
STUB
chmod +x "$workdir/bin/claude"

prompt_file="$workdir/prompt.txt"
echo "stub prompt" > "$prompt_file"

invoke_with_stub_log() {
  local stub_log="$1"
  local output_file="$2"
  shift 2
  HARNESS_TEST_STUB_LOG="$stub_log" \
    PATH="$workdir/bin:$PATH" \
    "$script" \
      --agent harness-evaluator \
      --prompt-file "$prompt_file" \
      --output-file "$output_file" \
      "$@"
}

scenario=1
echo "[$scenario] valid frontmatter result_text passes through end-to-end"
stub_log1="$workdir/stub1.jsonl"
out1="$workdir/out1.md"
python3 - "$stub_log1" <<'PY'
import json, sys
p = open(sys.argv[1], "w")
p.write(json.dumps({"type": "system", "session_id": "s-abc"}) + "\n")
p.write(json.dumps({
    "type": "result",
    "session_id": "s-abc",
    "is_error": False,
    "result": "---\nverdict: pass\nscore: 9\n---\n\nEvaluation body.\n",
}) + "\n")
p.close()
PY
invoke_with_stub_log "$stub_log1" "$out1" > /dev/null 2>&1
assert_contains "$out1" "verdict: pass"
assert_contains "$out1" "Evaluation body."
((scenario++))

echo "[$scenario] session-id placeholder is stamped from proof file"
stub_log_stamp="$workdir/stub-stamp.jsonl"
out_stamp="$workdir/out-stamp.md"
session_stamp="$workdir/evaluator-session-id.txt"
python3 - "$stub_log_stamp" <<'PY'
import json, sys
with open(sys.argv[1], "w") as p:
    p.write(json.dumps({"type": "system", "session_id": "s-stamp"}) + "\n")
    p.write(json.dumps({
        "type": "result",
        "session_id": "s-stamp",
        "is_error": False,
        "result": "---\nverdict: pass\nevaluator_session_id: __PENDING_SESSION_ID__\n---\n\nEvaluation body.\n",
    }) + "\n")
PY
invoke_with_stub_log "$stub_log_stamp" "$out_stamp" --session-id-file "$session_stamp" > /dev/null 2>&1
assert_contains "$session_stamp" "s-stamp"
assert_contains "$out_stamp" "evaluator_session_id: s-stamp"
assert_not_contains "$out_stamp" "__PENDING_SESSION_ID__"
((scenario++))

echo "[$scenario] missing session-id placeholder fails loudly when proof file is requested"
stub_log_missing_placeholder="$workdir/stub-missing-placeholder.jsonl"
out_missing_placeholder="$workdir/out-missing-placeholder.md"
session_missing_placeholder="$workdir/missing-placeholder-session-id.txt"
python3 - "$stub_log_missing_placeholder" <<'PY'
import json, sys
with open(sys.argv[1], "w") as p:
    p.write(json.dumps({"type": "system", "session_id": "s-no-placeholder"}) + "\n")
    p.write(json.dumps({
        "type": "result",
        "session_id": "s-no-placeholder",
        "is_error": False,
        "result": "---\nverdict: pass\n---\n\nEvaluation body.\n",
    }) + "\n")
PY
set +e
invoke_with_stub_log "$stub_log_missing_placeholder" "$out_missing_placeholder" --session-id-file "$session_missing_placeholder" > "$workdir/missing-placeholder.log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "scenario $scenario: expected non-zero exit when evaluator_session_id placeholder is missing" >&2
  cat "$workdir/missing-placeholder.log" >&2
  exit 1
fi
assert_contains "$workdir/missing-placeholder.log" "missing evaluator_session_id placeholder __PENDING_SESSION_ID__"
((scenario++))

echo "[$scenario] body-only session-id placeholder fails loudly"
stub_log_body_only_placeholder="$workdir/stub-body-only-placeholder.jsonl"
out_body_only_placeholder="$workdir/out-body-only-placeholder.md"
session_body_only_placeholder="$workdir/body-only-placeholder-session-id.txt"
python3 - "$stub_log_body_only_placeholder" <<'PY'
import json, sys
with open(sys.argv[1], "w") as p:
    p.write(json.dumps({"type": "system", "session_id": "s-body-only"}) + "\n")
    p.write(json.dumps({
        "type": "result",
        "session_id": "s-body-only",
        "is_error": False,
        "result": "---\nverdict: pass\n---\n\nBody mentions __PENDING_SESSION_ID__ but frontmatter omits evaluator_session_id.\n",
    }) + "\n")
PY
set +e
invoke_with_stub_log "$stub_log_body_only_placeholder" "$out_body_only_placeholder" --session-id-file "$session_body_only_placeholder" > "$workdir/body-only-placeholder.log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "scenario $scenario: expected non-zero exit when placeholder is outside evaluator_session_id frontmatter" >&2
  cat "$workdir/body-only-placeholder.log" >&2
  cat "$out_body_only_placeholder" >&2
  exit 1
fi
assert_contains "$workdir/body-only-placeholder.log" "missing evaluator_session_id placeholder __PENDING_SESSION_ID__"
((scenario++))

echo "[$scenario] backtick-yaml-fenced result_text is normalized"
stub_log2="$workdir/stub2.jsonl"
out2="$workdir/out2.md"
python3 - "$stub_log2" <<'PY'
import json, sys
fenced = "```yaml\n---\nverdict: review\n---\n\nNotes\n```\n"
with open(sys.argv[1], "w") as p:
    p.write(json.dumps({"type": "system", "session_id": "s-xyz"}) + "\n")
    p.write(json.dumps({
        "type": "result",
        "session_id": "s-xyz",
        "is_error": False,
        "result": fenced,
    }) + "\n")
PY
invoke_with_stub_log "$stub_log2" "$out2" > /dev/null 2>&1
first_line=$(head -n 1 "$out2")
if [[ "$first_line" != "---" ]]; then
  echo "scenario $scenario: first line of $out2 is not '---' (got '$first_line')" >&2
  cat "$out2" >&2
  exit 1
fi
assert_contains "$out2" "verdict: review"
((scenario++))

echo "[$scenario] missing closing '---' triggers fail-loud + parse-error artifact"
stub_log3="$workdir/stub3.jsonl"
out3="$workdir/out3.md"
python3 - "$stub_log3" <<'PY'
import json, sys
broken = "---\nverdict: pass\nnotes: no closing fence\n"
with open(sys.argv[1], "w") as p:
    p.write(json.dumps({"type": "system", "session_id": "s-bad"}) + "\n")
    p.write(json.dumps({
        "type": "result",
        "session_id": "s-bad",
        "is_error": False,
        "result": broken,
    }) + "\n")
PY
set +e
invoke_with_stub_log "$stub_log3" "$out3" > "$workdir/out3.log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "scenario $scenario: expected non-zero exit, got 0" >&2
  cat "$workdir/out3.log" >&2
  exit 1
fi
assert_contains "$out3" "result: parse-error"
assert_contains "$out3" "agent: harness-evaluator"
((scenario++))

echo "[$scenario] is_error=true propagates through normalize"
stub_log4="$workdir/stub4.jsonl"
out4="$workdir/out4.md"
python3 - "$stub_log4" <<'PY'
import json, sys
result = "---\nverdict: error\ndetail: agent crashed\n---\n"
with open(sys.argv[1], "w") as p:
    p.write(json.dumps({"type": "system", "session_id": "s-err"}) + "\n")
    p.write(json.dumps({
        "type": "result",
        "session_id": "s-err",
        "is_error": True,
        "result": result,
    }) + "\n")
PY
set +e
invoke_with_stub_log "$stub_log4" "$out4" > "$workdir/out4.log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 1 ]]; then
  echo "scenario $scenario: expected exit 1 (is_error), got $rc" >&2
  cat "$workdir/out4.log" >&2
  exit 1
fi
# File should still contain the (well-formed) error artifact for retro.
assert_contains "$out4" "verdict: error"

echo "claude-agent-invoke e2e fail-loud test passed (${scenario} scenarios)"
