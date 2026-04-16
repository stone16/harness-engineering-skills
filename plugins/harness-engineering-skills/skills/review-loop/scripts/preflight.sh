#!/usr/bin/env bash
set -uo pipefail

# preflight.sh — Runs ALL preflight + context collection in a single execution.
# Eliminates Claude API round-trip overhead (15+ tool calls → 1).
#
# Outputs key-value blocks with everything Claude needs to proceed.
# Also creates the session directory and writes rounds.json.
#
# Usage:
#   ./preflight.sh [--peer codex|gemini] [--max-rounds N]
#                  [--scope auto|diff|branch|pr] [--timeout N]
#                  [--commit-sha SHA]

# --- Precedence: defaults < config.json < CLI args ---
# 1. Start with defaults
PEER="codex"
MAX_ROUNDS=5
SCOPE_PREF="auto"
TIMEOUT=600
COMMIT_SHA=""

# 2. Merge project config over defaults
CONFIG_FILE=".review-loop/config.json"
if [[ -f "$CONFIG_FILE" ]]; then
  cfg_peer=$(grep -o '"peer_reviewer"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | grep -o '"[^"]*"$' | tr -d '"')
  cfg_max=$(grep -o '"max_rounds"[[:space:]]*:[[:space:]]*[0-9]*' "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*$')
  cfg_timeout=$(grep -o '"timeout_per_round"[[:space:]]*:[[:space:]]*[0-9]*' "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*$')
  [[ -n "${cfg_peer:-}" ]] && PEER="$cfg_peer"
  [[ -n "${cfg_max:-}" ]] && MAX_ROUNDS="$cfg_max"
  [[ -n "${cfg_timeout:-}" ]] && TIMEOUT="$cfg_timeout"
fi

# 3. CLI args override everything (highest precedence)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --peer)       PEER="$2"; shift 2 ;;
    --max-rounds) MAX_ROUNDS="$2"; shift 2 ;;
    --scope)      SCOPE_PREF="$2"; shift 2 ;;
    --timeout)    TIMEOUT="$2"; shift 2 ;;
    --commit-sha) COMMIT_SHA="$2"; shift 2 ;;
    *) echo "Error: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Step 0.2: Check peer CLI ---
if ! command -v "$PEER" &>/dev/null; then
  # Try alternative
  if [[ "$PEER" == "codex" ]] && command -v gemini &>/dev/null; then
    echo "Warning: codex not found, falling back to gemini" >&2
    PEER="gemini"
  elif [[ "$PEER" == "gemini" ]] && command -v codex &>/dev/null; then
    echo "Warning: gemini not found, falling back to codex" >&2
    PEER="codex"
  else
    echo "Error: Neither codex nor gemini CLI found" >&2
    exit 1
  fi
fi

# --- Step 0.3: Detect base branch and repo root ---
BASE_BRANCH="$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|origin/||')"
if [[ -z "$BASE_BRANCH" ]]; then
  for branch in main master develop; do
    git rev-parse --verify "origin/$branch" &>/dev/null && BASE_BRANCH="$branch" && break
  done
fi
BASE_BRANCH="${BASE_BRANCH:-main}"
REPO_ROOT="$(pwd -P)"

# --- Step 0.4: Detect scope ---
SCOPE=""
SCOPE_DETAIL=""
TARGET_FILES=""

if [[ "$SCOPE_PREF" == "auto" || "$SCOPE_PREF" == "diff" ]]; then
  LOCAL_DIFF="$(git diff --stat 2>/dev/null)"
  STAGED_DIFF="$(git diff --cached --stat 2>/dev/null)"
  UNTRACKED_FILES="$(git ls-files --others --exclude-standard 2>/dev/null)"
  if [[ -n "$LOCAL_DIFF" || -n "$STAGED_DIFF" || -n "$UNTRACKED_FILES" ]]; then
    SCOPE="local-diff"
    UNTRACKED_COUNT="$(printf '%s' "$UNTRACKED_FILES" | sed '/^$/d' | wc -l | tr -d ' ')"
    DIFF_STAT="$(printf '%s\n%s\n' "$LOCAL_DIFF" "$STAGED_DIFF" | sed '/^$/d' | tail -1)"
    if [[ -n "$DIFF_STAT" && -n "$UNTRACKED_FILES" ]]; then
      SCOPE_DETAIL="${DIFF_STAT}; ${UNTRACKED_COUNT} untracked"
    elif [[ -n "$DIFF_STAT" ]]; then
      SCOPE_DETAIL="$DIFF_STAT"
    else
      SCOPE_DETAIL="${UNTRACKED_COUNT} untracked file(s)"
    fi
    TARGET_FILES="$(
      {
        git diff --name-only 2>/dev/null
        git diff --cached --name-only 2>/dev/null
        printf '%s\n' "$UNTRACKED_FILES"
      } | sed '/^$/d' | sort -u
    )"
  fi
fi

# Specific commit SHA (only when explicitly requested)
if [[ -z "$SCOPE" && -n "$COMMIT_SHA" ]]; then
  if git rev-parse --verify "$COMMIT_SHA" &>/dev/null; then
    SCOPE="commit-${COMMIT_SHA:0:7}"
    SCOPE_DETAIL="commit $(git log --oneline -1 "$COMMIT_SHA" 2>/dev/null)"
    TARGET_FILES="$(git show --name-only --format='' "$COMMIT_SHA" 2>/dev/null | sed '/^$/d' | sort -u)"
  else
    echo "Error: Invalid commit SHA: $COMMIT_SHA" >&2
    exit 1
  fi
fi

# Branch has unpushed commits
if [[ -z "$SCOPE" && ("$SCOPE_PREF" == "auto" || "$SCOPE_PREF" == "branch") ]]; then
  BRANCH_LOG="$(git log "origin/$BASE_BRANCH..HEAD" --oneline 2>/dev/null)"
  if [[ -n "$BRANCH_LOG" ]]; then
    SCOPE="branch-commits"
    COMMIT_COUNT="$(echo "$BRANCH_LOG" | wc -l | tr -d ' ')"
    SCOPE_DETAIL="${COMMIT_COUNT} commits ahead of origin/$BASE_BRANCH"
    TARGET_FILES="$(git diff --name-only "origin/$BASE_BRANCH..HEAD" 2>/dev/null | sed '/^$/d')"
  fi
fi

if [[ -z "$SCOPE" && ("$SCOPE_PREF" == "auto" || "$SCOPE_PREF" == "pr") ]]; then
  PR_JSON="$(gh pr view --json number,title 2>/dev/null)"
  if [[ -n "$PR_JSON" ]]; then
    PR_NUM="$(echo "$PR_JSON" | grep -o '"number":[0-9]*' | grep -o '[0-9]*')"
    PR_TITLE="$(echo "$PR_JSON" | grep -o '"title":"[^"]*"' | sed 's/"title":"//;s/"$//')"
    SCOPE="pr-${PR_NUM}"
    SCOPE_DETAIL="PR #${PR_NUM}: ${PR_TITLE}"
    TARGET_FILES="$(git diff --name-only "origin/$BASE_BRANCH..HEAD" 2>/dev/null | sed '/^$/d')"
    if [[ -z "$TARGET_FILES" ]]; then
      TARGET_FILES="$(gh pr diff "$PR_NUM" 2>/dev/null | sed -n 's#^+++ b/##p' | sed '/^\/dev\/null$/d;/^$/d' | sort -u)"
    fi
  fi
fi

if [[ -z "$SCOPE" ]]; then
  echo "Error: No changes detected. Nothing to review." >&2
  exit 1
fi

if [[ -z "$TARGET_FILES" ]]; then
  TARGET_FILES="(unable to auto-detect a file list; inspect the current repository using the scope above)"
fi

# --- Step 0.5: Create session directory ---
SCOPE_SHORT="$(echo "$SCOPE" | tr -d ' ' | head -c 30)"
SESSION_ID="$(date +%Y-%m-%d-%H%M%S)-${SCOPE_SHORT}"
SESSION_DIR=".review-loop/$SESSION_ID"
mkdir -p "$SESSION_DIR/peer-output"
ln -sfn "$SESSION_ID" .review-loop/latest

# --- Step 0.6: Auto-gitignore ---
grep -qxF '.review-loop/' .gitignore 2>/dev/null || echo '.review-loop/' >> .gitignore

# --- Step 0.7: Initialize rounds.json ---
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$SESSION_DIR/rounds.json" << ENDJSON
{
  "session": {
    "id": "${SESSION_ID}",
    "scope": "${SCOPE}",
    "scope_detail": "${SCOPE_DETAIL}",
    "peer": "${PEER}",
    "started_at": "${STARTED_AT}",
    "completed_at": null,
    "status": "in_progress",
    "total_rounds": 0
  },
  "rounds": [],
  "summary": {
    "total_findings": 0,
    "accepted": 0,
    "rejected_then_resolved": 0,
    "escalated": 0,
    "files_modified": []
  }
}
ENDJSON

# --- Step 0.8: Checkpoint commit ---
# Use `-a` (modifications/deletions of tracked files only) instead of `add -A`
# to avoid sweeping untracked files — which may contain secrets (.env, creds) —
# into the checkpoint commit on the branch under review.
git commit -am "review-loop: checkpoint before round 1" --allow-empty 2>/dev/null \
  || git commit -m "review-loop: checkpoint before round 1" --allow-empty 2>/dev/null

# --- Step 1.1: Collect project context ---
PROJECT_DESC=""
if [[ -f "CLAUDE.md" ]]; then
  # First 30 lines of CLAUDE.md for project context
  PROJECT_DESC="$(head -30 CLAUDE.md)"
elif [[ -f "package.json" ]]; then
  PROJECT_DESC="$(grep -E '"(name|description)"' package.json | head -2)"
elif [[ -f "README.md" ]]; then
  PROJECT_DESC="$(head -10 README.md)"
fi

# --- Output everything as key-value blocks ---
TARGET_FILES_B64="$(printf '%s' "$TARGET_FILES" | base64)"
PROJECT_B64="$(printf '%s' "$PROJECT_DESC" | base64)"

cat << ENDOUT
PREFLIGHT_OK
SESSION_DIR=${SESSION_DIR}
SESSION_ID=${SESSION_ID}
PEER=${PEER}
MAX_ROUNDS=${MAX_ROUNDS}
TIMEOUT=${TIMEOUT}
SCOPE=${SCOPE}
SCOPE_DETAIL=${SCOPE_DETAIL}
BASE_BRANCH=${BASE_BRANCH}
REPO_ROOT=${REPO_ROOT}
STARTED_AT=${STARTED_AT}
TARGET_FILES_B64_START
${TARGET_FILES_B64}
TARGET_FILES_B64_END
PROJECT_B64_START
${PROJECT_B64}
PROJECT_B64_END
ENDOUT
