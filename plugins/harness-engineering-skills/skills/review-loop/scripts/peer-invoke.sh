#!/usr/bin/env bash
set -uo pipefail

# peer-invoke.sh — Thin wrapper for Codex/Gemini CLI invocation
# Abstracts CLI differences so SKILL.md doesn't care which peer is used.
# Codex inspects local files directly from the current repository workspace.
#
# Exit codes: 0=success, 1=error, 124=timeout
#
# Usage:
#   ./peer-invoke.sh --peer codex --prompt-file /tmp/prompt.md \
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
peer_exit_code=0

cleanup() {
  if [[ -n "$RUN_LOG" && -f "$RUN_LOG" ]]; then
    rm -f "$RUN_LOG"
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
  gemini)
    command -v gemini &>/dev/null || { echo "Error: gemini CLI not found" >&2; exit 1; }
    $TIMEOUT_CMD "$TIMEOUT" gemini -p "$PROMPT_CONTENT" > "$OUTPUT_FILE" 2>&1
    peer_exit_code=$?
    ;;
  *)
    echo "Error: Unsupported peer: $PEER. Use 'codex' or 'gemini'." >&2
    exit 1
    ;;
esac

exit_code=$peer_exit_code
if [[ $exit_code -eq 124 ]]; then
  echo "Error: Peer review timed out after ${TIMEOUT}s" >&2
fi
exit $exit_code
