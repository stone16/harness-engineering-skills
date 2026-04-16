#!/usr/bin/env bash
set -uo pipefail

# claude-agent-invoke.sh — Run a Claude review-role agent from Codex-hosted Harness flows.
# Uses an installed Claude agent when available, otherwise falls back to the repo's
# dotfiles/agents/<name>.md prompt body.

AGENT_NAME=""
PROMPT_FILE=""
OUTPUT_FILE=""
RESUME_SESSION=""
SESSION_ID_FILE=""
MODEL_OVERRIDE=""
TIMEOUT="${HARNESS_CLAUDE_TIMEOUT:-900}"
BYPASS_PERMISSIONS="${HARNESS_CLAUDE_SKIP_PERMISSIONS:-1}"
OUTPUT_FORMAT="${HARNESS_CLAUDE_OUTPUT_FORMAT:-stream-json}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT_NAME="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --output-file) OUTPUT_FILE="$2"; shift 2 ;;
    --resume-session) RESUME_SESSION="$2"; shift 2 ;;
    --session-id-file) SESSION_ID_FILE="$2"; shift 2 ;;
    --model) MODEL_OVERRIDE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --no-bypass-permissions) BYPASS_PERMISSIONS=0; shift ;;
    *) echo "Error: Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$AGENT_NAME" || -z "$PROMPT_FILE" || -z "$OUTPUT_FILE" ]]; then
  echo "Error: --agent, --prompt-file, and --output-file are required" >&2
  exit 1
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Error: Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

command -v claude &>/dev/null || { echo "Error: claude CLI not found" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Find the skillset repo root for fallback agent files.
# Uses git to avoid fragile relative-path assumptions about install depth.
SKILLSET_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel 2>/dev/null || true)"

USER_AGENT_FILE="$HOME/.claude/agents/${AGENT_NAME}.md"
if [[ -n "$SKILLSET_ROOT" ]]; then
  REPO_AGENT_FILE="$SKILLSET_ROOT/dotfiles/agents/${AGENT_NAME}.md"
else
  REPO_AGENT_FILE=""
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"
if [[ -n "$SESSION_ID_FILE" ]]; then
  mkdir -p "$(dirname "$SESSION_ID_FILE")"
fi

RUN_LOG="$(mktemp "${TMPDIR:-/tmp}/harness-claude-agent-log.XXXXXX")"
RUN_ERR="$(mktemp "${TMPDIR:-/tmp}/harness-claude-agent-stderr.XXXXXX")"
cleanup() {
  [[ -f "$RUN_LOG" ]] && rm -f "$RUN_LOG"
  [[ -f "$RUN_ERR" ]] && rm -f "$RUN_ERR"
}
trap cleanup EXIT

# Cross-platform timeout: GNU timeout -> gtimeout (brew) -> pure bash fallback.
if command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout"
else
  run_with_timeout() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    ( sleep "$secs" && kill "$pid" 2>/dev/null ) &
    local watcher=$!
    wait "$pid" 2>/dev/null
    local result=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    if [[ $result -eq 137 || $result -eq 143 ]]; then
      return 124
    fi
    return "$result"
  }
  TIMEOUT_CMD="run_with_timeout"
fi

resolve_agent_prompt() {
  local agent_file="$1"
  python3 - "$agent_file" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
parts = text.split('---', 2)
if len(parts) >= 3:
    sys.stdout.write(parts[2].lstrip('\n'))
else:
    sys.stdout.write(text)
PY
}

resolve_agent_model() {
  local agent_file="$1"
  python3 - "$agent_file" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text().split('---', 2)
if len(text) < 3:
    sys.exit(0)
frontmatter = text[1].splitlines()
for line in frontmatter:
    if line.startswith("model:"):
        value = line.split(":", 1)[1].strip()
        if value and value != "inherit":
            sys.stdout.write(value)
        break
PY
}

parse_claude_json() {
  local log_file="$1"
  local output_file="$2"
  local session_id_file="${3:-}"

  python3 - "$log_file" "$output_file" "$session_id_file" <<'PY'
import json
import pathlib
import sys

log_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
session_id_path = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else None

text = log_path.read_text()
try:
    payload = json.loads(text)
    events = payload if isinstance(payload, list) else [payload]
except json.JSONDecodeError:
    events = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue

session_id = ""
result_text = None
is_error = False

for event in events:
    if not isinstance(event, dict):
        continue
    session_id = event.get("session_id") or session_id
    if event.get("type") == "result":
        is_error = bool(event.get("is_error"))
        result_text = event.get("result")
        session_id = event.get("session_id") or session_id

if result_text is None:
    raise SystemExit("Error: Claude agent output did not include a result payload")

if output_path.exists():
    existing_text = output_path.read_text()
else:
    existing_text = ""

if existing_text.strip() and not result_text.lstrip().startswith("---"):
    # Some Claude agents write the requested artifact directly and return a
    # prose summary as their final result. Preserve the structured artifact in
    # that case; otherwise the harness gate loses its frontmatter.
    pass
else:
    output_path.write_text(result_text)

if session_id_path:
    session_id_path.write_text(f"{session_id}\n")

if is_error:
    print(f"Error: Claude agent returned an error: {result_text}", file=sys.stderr)
    sys.exit(1)
PY
}

# Stay in the caller's working directory (the user's project).
# Do NOT cd to the skillset repo — Claude needs project context.

common_claude_args=(-p --output-format "$OUTPUT_FORMAT")
if [[ "$BYPASS_PERMISSIONS" == "1" ]]; then
  common_claude_args+=(--dangerously-skip-permissions)
fi
if [[ "$OUTPUT_FORMAT" == "stream-json" ]]; then
  common_claude_args+=(--verbose)
fi

if [[ -n "$RESUME_SESSION" ]]; then
  $TIMEOUT_CMD "$TIMEOUT" claude -r "$RESUME_SESSION" "${common_claude_args[@]}" \
    < "$PROMPT_FILE" > "$RUN_LOG" 2> "$RUN_ERR"
  exit_code=$?
else
  if [[ -f "$USER_AGENT_FILE" ]]; then
    CLAUDE_CMD=(claude --agent "$AGENT_NAME" "${common_claude_args[@]}")
  elif [[ -n "$REPO_AGENT_FILE" && -f "$REPO_AGENT_FILE" ]]; then
    AGENT_PROMPT="$(resolve_agent_prompt "$REPO_AGENT_FILE")"
    AGENT_MODEL="${MODEL_OVERRIDE:-$(resolve_agent_model "$REPO_AGENT_FILE")}"
    CLAUDE_CMD=(claude "${common_claude_args[@]}" --append-system-prompt "$AGENT_PROMPT")
    if [[ -n "$AGENT_MODEL" ]]; then
      CLAUDE_CMD+=(--model "$AGENT_MODEL")
    fi
  else
    echo "Error: Agent not found in ~/.claude/agents or repo dotfiles: $AGENT_NAME" >&2
    exit 1
  fi

  $TIMEOUT_CMD "$TIMEOUT" "${CLAUDE_CMD[@]}" < "$PROMPT_FILE" > "$RUN_LOG" 2> "$RUN_ERR"
  exit_code=$?
fi

cat "$RUN_LOG" >&2
cat "$RUN_ERR" >&2

if [[ $exit_code -ne 0 ]]; then
  if [[ $exit_code -eq 124 ]]; then
    echo "Error: Claude agent timed out after ${TIMEOUT}s" >&2
  fi
  exit "$exit_code"
fi

parse_claude_json "$RUN_LOG" "$OUTPUT_FILE" "$SESSION_ID_FILE"
