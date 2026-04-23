#!/usr/bin/env bash
set -uo pipefail

# peer-invoke.sh — Thin wrapper for Codex/Claude/Gemini CLI invocation
# Abstracts CLI differences so SKILL.md doesn't care which peer is used.
# Peers inspect local files directly from the current repository workspace.
#
# Exit codes: 0=success, 1=error, 124=timeout
#
# Usage:
#   ./peer-invoke.sh --peer codex --prompt-file /tmp/prompt.md \
#     --output-file .review-loop/session/peer-output/round-1-raw.txt --timeout 600
#   ./peer-invoke.sh --peer claude --prompt-file /tmp/prompt.md \
#     --output-file .review-loop/session/peer-output/round-1-raw.txt --timeout 600
#   ./peer-invoke.sh --peer codex --resume-session <session-id> \
#     --prompt-file /tmp/reround.md --output-file .review-loop/session/peer-output/round-2-raw.txt

PEER=""
PROMPT_FILE=""
OUTPUT_FILE=""
TIMEOUT=600
RESUME_SESSION=""
SESSION_ID_FILE=""
PRESERVE_CODEX_API_KEY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --peer)         PEER="$2"; shift 2 ;;
    --prompt-file)  PROMPT_FILE="$2"; shift 2 ;;
    --output-file)  OUTPUT_FILE="$2"; shift 2 ;;
    --timeout)      TIMEOUT="$2"; shift 2 ;;
    --resume-session) RESUME_SESSION="$2"; shift 2 ;;
    --session-id-file) SESSION_ID_FILE="$2"; shift 2 ;;
    --preserve-codex-api-key) PRESERVE_CODEX_API_KEY=1; shift ;;
    *) echo "Error: Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PEER" || -z "$PROMPT_FILE" || -z "$OUTPUT_FILE" ]]; then
  echo "Error: --peer, --prompt-file, and --output-file are required" >&2
  exit 1
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Error: Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"
if [[ -n "$SESSION_ID_FILE" ]]; then
  mkdir -p "$(dirname "$SESSION_ID_FILE")"
fi
REPO_ROOT="$(pwd -P)"

# Cross-platform timeout: GNU timeout → gtimeout (brew) → fallback
if command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout"
else
  # Pure-bash fallback: run command in background, kill after TIMEOUT
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
    # If killed by our watcher, return 124 (matching GNU timeout convention)
    if [[ $result -eq 137 || $result -eq 143 ]]; then
      return 124
    fi
    return "$result"
  }
  TIMEOUT_CMD="run_with_timeout"
fi

PROMPT_CONTENT="$(cat "$PROMPT_FILE")"

TEMP_CODEX_HOME=""
RUN_LOG=""
RUN_ERR=""
peer_exit_code=0

cleanup() {
  if [[ -n "$RUN_LOG" && -f "$RUN_LOG" ]]; then
    rm -f "$RUN_LOG"
  fi
  if [[ -n "$RUN_ERR" && -f "$RUN_ERR" ]]; then
    rm -f "$RUN_ERR"
  fi
  if [[ -n "$TEMP_CODEX_HOME" && -d "$TEMP_CODEX_HOME" ]]; then
    rm -rf "$TEMP_CODEX_HOME"
  fi
}

trap cleanup EXIT

escape_toml_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

prepare_minimal_codex_home() {
  local source_home="${CODEX_HOME:-$HOME/.codex}"
  local source_config="$source_home/config.toml"
  local escaped_repo_root
  local entry
  local name

  if [[ ! -d "$source_home" ]]; then
    echo "Error: Codex home not found: $source_home" >&2
    exit 1
  fi

  TEMP_CODEX_HOME="$(mktemp -d "${TMPDIR:-/tmp}/review-loop-codex-home.XXXXXX")"

  shopt -s dotglob nullglob
  for entry in "$source_home"/*; do
    name="${entry##*/}"
    [[ "$name" == "config.toml" ]] && continue
    ln -s "$entry" "$TEMP_CODEX_HOME/$name"
  done
  shopt -u dotglob nullglob

  escaped_repo_root="$(escape_toml_string "$REPO_ROOT")"

  {
    if [[ -f "$source_config" ]]; then
      awk '
        /^\[/ { exit }
        /^[[:space:]]*(model|model_reasoning_effort|model_reasoning_summary|model_verbosity|network_access|service_tier)[[:space:]]*=/ { print }
      ' "$source_config"
    fi
    printf '\n[projects."%s"]\n' "$escaped_repo_root"
    printf 'trust_level = "trusted"\n'
  } > "$TEMP_CODEX_HOME/config.toml"
}

extract_session_id() {
  local log_file="$1"
  awk -F': ' '/^session id:/ { print $2; exit }' "$log_file"
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
    if isinstance(event, dict):
        session_id = event.get("session_id") or session_id
        if event.get("type") == "result":
            is_error = bool(event.get("is_error"))
            result_text = event.get("result")
            session_id = event.get("session_id") or session_id

if result_text is None:
    for event in reversed(events):
        if not isinstance(event, dict):
            continue
        message = event.get("message")
        if not isinstance(message, dict):
            continue
        content = message.get("content")
        if not isinstance(content, list):
            continue
        text_parts = [
            part.get("text", "")
            for part in content
            if isinstance(part, dict) and part.get("type") == "text"
        ]
        if text_parts:
            result_text = "\n".join(part for part in text_parts if part)
            session_id = event.get("session_id") or session_id
            break

if result_text is None:
    print("Error: Claude output did not include a result payload", file=sys.stderr)
    sys.exit(1)

output_path.write_text(result_text)

if session_id_path:
    session_id_path.parent.mkdir(parents=True, exist_ok=True)
    session_id_path.write_text(f"{session_id}\n")

if is_error:
    print(f"Error: Claude peer returned an error: {result_text}", file=sys.stderr)
    sys.exit(1)
PY
}

case "$PEER" in
  codex)
    command -v codex &>/dev/null || { echo "Error: codex CLI not found. Install: npm i -g @openai/codex" >&2; exit 1; }
    prepare_minimal_codex_home
    RUN_LOG="$(mktemp "${TMPDIR:-/tmp}/review-loop-codex-log.XXXXXX")"
    cd "$REPO_ROOT" || exit 1

    if [[ -n "$RESUME_SESSION" ]]; then
      if [[ "$PRESERVE_CODEX_API_KEY" -eq 1 ]]; then
        $TIMEOUT_CMD "$TIMEOUT" env "CODEX_HOME=$TEMP_CODEX_HOME" codex exec resume \
          --dangerously-bypass-approvals-and-sandbox \
          --output-last-message "$OUTPUT_FILE" \
          "$RESUME_SESSION" - < "$PROMPT_FILE" > "$RUN_LOG" 2>&1
      else
        $TIMEOUT_CMD "$TIMEOUT" env -u CODEX_API_KEY "CODEX_HOME=$TEMP_CODEX_HOME" codex exec resume \
          --dangerously-bypass-approvals-and-sandbox \
          --output-last-message "$OUTPUT_FILE" \
          "$RESUME_SESSION" - < "$PROMPT_FILE" > "$RUN_LOG" 2>&1
      fi
    else
      if [[ "$PRESERVE_CODEX_API_KEY" -eq 1 ]]; then
        $TIMEOUT_CMD "$TIMEOUT" env "CODEX_HOME=$TEMP_CODEX_HOME" codex exec \
          --dangerously-bypass-approvals-and-sandbox \
          --output-last-message "$OUTPUT_FILE" \
          - < "$PROMPT_FILE" > "$RUN_LOG" 2>&1
      else
        $TIMEOUT_CMD "$TIMEOUT" env -u CODEX_API_KEY "CODEX_HOME=$TEMP_CODEX_HOME" codex exec \
          --dangerously-bypass-approvals-and-sandbox \
          --output-last-message "$OUTPUT_FILE" \
          - < "$PROMPT_FILE" > "$RUN_LOG" 2>&1
      fi
    fi
    peer_exit_code=$?

    cat "$RUN_LOG" >&2

    if [[ -n "$SESSION_ID_FILE" ]]; then
      session_id="$(extract_session_id "$RUN_LOG")"
      if [[ -n "$session_id" ]]; then
        printf '%s\n' "$session_id" > "$SESSION_ID_FILE"
      fi
    fi
    ;;
  claude)
    command -v claude &>/dev/null || { echo "Error: claude CLI not found" >&2; exit 1; }
    RUN_LOG="$(mktemp "${TMPDIR:-/tmp}/review-loop-claude-log.XXXXXX")"
    RUN_ERR="$(mktemp "${TMPDIR:-/tmp}/review-loop-claude-stderr.XXXXXX")"
    cd "$REPO_ROOT" || exit 1

    CLAUDE_ARGS=(-p --output-format "${REVIEW_LOOP_CLAUDE_OUTPUT_FORMAT:-stream-json}")
    if [[ "${REVIEW_LOOP_CLAUDE_SKIP_PERMISSIONS:-1}" == "1" ]]; then
      CLAUDE_ARGS+=(--dangerously-skip-permissions)
    fi
    if [[ "${REVIEW_LOOP_CLAUDE_OUTPUT_FORMAT:-stream-json}" == "stream-json" ]]; then
      CLAUDE_ARGS+=(--verbose)
    fi

    if [[ -n "$RESUME_SESSION" ]]; then
      $TIMEOUT_CMD "$TIMEOUT" claude -r "$RESUME_SESSION" "${CLAUDE_ARGS[@]}" \
        < "$PROMPT_FILE" > "$RUN_LOG" 2> "$RUN_ERR"
    else
      $TIMEOUT_CMD "$TIMEOUT" claude "${CLAUDE_ARGS[@]}" \
        < "$PROMPT_FILE" > "$RUN_LOG" 2> "$RUN_ERR"
    fi
    peer_exit_code=$?

    cat "$RUN_LOG" >&2
    cat "$RUN_ERR" >&2

    if [[ $peer_exit_code -eq 0 ]]; then
      if ! parse_claude_json "$RUN_LOG" "$OUTPUT_FILE" "$SESSION_ID_FILE"; then
        peer_exit_code=1
      fi
    fi
    ;;
  gemini)
    command -v gemini &>/dev/null || { echo "Error: gemini CLI not found" >&2; exit 1; }
    $TIMEOUT_CMD "$TIMEOUT" gemini -p "$PROMPT_CONTENT" > "$OUTPUT_FILE" 2>&1
    peer_exit_code=$?
    ;;
  *)
    echo "Error: Unsupported peer: $PEER. Use 'codex', 'claude', or 'gemini'." >&2
    exit 1
    ;;
esac

exit_code=$peer_exit_code
if [[ $exit_code -eq 124 ]]; then
  echo "Error: Peer review timed out after ${TIMEOUT}s" >&2
fi
exit $exit_code
