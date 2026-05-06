#!/usr/bin/env bash
set -uo pipefail

# harness-engine.sh — Deterministic state machine for harness orchestration.
# Handles directory creation, git-state.json, SHA recording, gitignore, state
# transition validation, context assembly, and abort/rollback.
#
# Eliminates 15+ LLM tool calls per operation by collapsing file-system and git
# bookkeeping into single bash invocations (same pattern as review-loop preflight.sh).
#
# Usage:
#   harness-engine.sh <command> [options]
#
# Commands:
#   read-config         Merge defaults + config.json + CLI overrides, output config
#   init                Create .harness/<task-id>/ + git-state.json + gitignore
#   status              Read git-state.json, output current phase/checkpoint/iteration
#   discover            Scan .harness/ for approved specs on current branch
#   begin-checkpoint    Record baseline_sha, create checkpoint directory structure
#   end-iteration       Record iteration end_sha after Generator commits
#   pass-checkpoint     Verify evaluation PASS, write status.md=PASS, record final_sha
#   begin-e2e           Record e2e_baseline_sha, create e2e directory structure
#   pass-e2e            Verify E2E report PASS, write status.md=PASS, record e2e_final_sha
#   pass-review-loop    Verify completed review-loop artifacts, advance phase
#   skip-review-loop    Skip review-loop when config disables it
#   begin-full-verify   Start full-verify phase (record baseline SHA)
#   pass-full-verify    Mark full-verify as PASS (requires verification-report.md)
#   skip-full-verify    Skip full-verify (only if config enables skip)
#   create-pr           Create PR or write manual handoff based on autonomous_pr
#   pass-pr             Record PR URL, advance phase
#   complete            Mark task as done
#   abort               Git reset --hard to baseline_sha, mark ABORTED
#   assemble-context    Extract checkpoint context from spec.md -> output context.md
#   assemble-retro-input  Summarize all checkpoint data -> output retro-input.md
#   scope-check         List files changed against freshly fetched origin/<base>
#   validate-transition Check state transition legality

# ============================================================================
# JSON Helper Functions
# ============================================================================
# Primary: python3 one-liners. Fallback: grep/sed for simple reads.
# All writes use atomic temp-file + mv to prevent corruption.

json_get() {
  local file="$1" key="$2"
  if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for k in sys.argv[2].split('.'):
    if isinstance(data, dict):
        data = data.get(k, '')
    else:
        data = ''
        break
print(data if data != '' else '')
" "$file" "$key"
  else
    # Fallback: simple top-level key extraction
    grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | head -1 | sed 's/.*: *"//;s/"$//'
  fi
}

json_set() {
  local file="$1" key="$2" value="$3"
  local tmp
  tmp=$(mktemp)
  python3 -c "
import json, sys
filepath, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(filepath) as f:
    data = json.load(f)
keys = key.split('.')
obj = data
for k in keys[:-1]:
    if k not in obj:
        obj[k] = {}
    obj = obj[k]
obj[keys[-1]] = value
with open(sys.argv[4], 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
" "$file" "$key" "$value" "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

json_add_iteration() {
  # Add a new iteration entry to a checkpoint in git-state.json
  local file="$1" checkpoint="$2" iteration="$3" end_sha="$4"
  local tmp
  tmp=$(mktemp)
  python3 -c "
import json, sys
filepath, cp_id, iter_id, sha, outpath = sys.argv[1:6]
with open(filepath) as f:
    data = json.load(f)
cp = data.setdefault('checkpoints', {}).setdefault(cp_id, {})
iters = cp.setdefault('iterations', {})
iters[iter_id] = {'end_sha': sha}
with open(outpath, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
" "$file" "$checkpoint" "$iteration" "$end_sha" "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

json_get_nested() {
  # Get a value from a nested path. Returns empty string if path doesn't exist.
  local file="$1" key="$2"
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for k in sys.argv[2].split('.'):
    if isinstance(data, dict) and k in data:
        data = data[k]
    else:
        print('')
        sys.exit(0)
print(data if data is not None else '')
" "$file" "$key"
}

json_count_checkpoints() {
  # Count checkpoints in git-state.json
  local file="$1"
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(len(data.get('checkpoints', {})))
" "$file"
}

json_list_checkpoints() {
  # List checkpoint IDs sorted
  local file="$1"
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for k in sorted(data.get('checkpoints', {}).keys()):
    print(k)
" "$file"
}

# ============================================================================
# Configuration
# ============================================================================

# Defaults
DEFAULT_MAX_SPEC_ROUNDS=3
DEFAULT_MAX_EVAL_ROUNDS=3
DEFAULT_CROSS_MODEL_REVIEW="true"
DEFAULT_CROSS_MODEL_PEER="codex"
DEFAULT_AUTO_RETRO="true"
DEFAULT_CLAUDE_MD_PATH="auto"
DEFAULT_MAX_VERIFY_ROUNDS=3
DEFAULT_COVERAGE_THRESHOLD=85
DEFAULT_SKIP_FULL_VERIFY="false"
DEFAULT_AUTONOMOUS_PR="true"

# Global options
TASK_ID=""
CHECKPOINT=""
ITERATION=""

# ============================================================================
# CLI Argument Parser
# ============================================================================

COMMAND=""
EXTRA_ARGS=()

parse_args() {
  if [[ $# -eq 0 ]]; then
    echo "Error: No command specified. Run with --help for usage." >&2
    exit 1
  fi

  COMMAND="$1"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id)     TASK_ID="$2"; shift 2 ;;
      --checkpoint)  CHECKPOINT="$2"; shift 2 ;;
      --iteration)   ITERATION="$2"; shift 2 ;;
      --help)        usage; exit 0 ;;
      *)             EXTRA_ARGS+=("$1"); shift ;;
    esac
  done
}

usage() {
  cat <<'EOF'
Usage: harness-engine.sh <command> [options]

Commands:
  read-config           Output merged configuration
  init                  Initialize .harness/<task-id>/ directory tree
  status                Show current execution state
  discover              Find approved specs on current branch
  begin-checkpoint      Start a new checkpoint (record baseline SHA)
  end-iteration         Record end of a Generator iteration
  pass-checkpoint       Mark checkpoint as PASS (requires evaluator PASS)
  begin-e2e             Start E2E verification phase
  pass-e2e              Mark E2E as PASS (requires E2E report PASS)
  pass-review-loop      Verify completed review-loop artifacts, advance phase
  skip-review-loop      Skip review-loop (only if config disables it)
  begin-full-verify     Start full-verify phase (record baseline SHA)
  pass-full-verify      Mark full-verify as PASS (requires verification-report.md)
  skip-full-verify      Skip full-verify (only if skip_full_verify=true in config)
  create-pr             Create PR or write pr-handoff.md based on autonomous_pr
  pass-pr               Record PR URL, advance phase (--pr-url required)
  complete              Mark task as done (phase → done)
  abort                 Abort current checkpoint (git reset --hard)
  assemble-context      Build context.md for a checkpoint
  assemble-retro-input  Build retro-input.md for retrospective
  scope-check           List changed files against freshly fetched origin/<base>
  validate-transition   Check if a state transition is legal

Options:
  --task-id ID          Task identifier (required for most commands)
  --checkpoint NN       Checkpoint number (zero-padded, e.g., 01)
  --iteration N         Iteration number
  --base-branch NAME    Base branch for scope-check (default: main)
  --help                Show this help
EOF
}

# ============================================================================
# Helpers
# ============================================================================

harness_dir() {
  echo ".harness/${TASK_ID}"
}

git_state_file() {
  echo "$(harness_dir)/git-state.json"
}

require_task_id() {
  if [[ -z "$TASK_ID" ]]; then
    echo "Error: --task-id is required for this command" >&2
    exit 1
  fi
}

require_checkpoint() {
  if [[ -z "$CHECKPOINT" ]]; then
    echo "Error: --checkpoint is required for this command" >&2
    exit 1
  fi
}

require_git_state() {
  local gs
  gs="$(git_state_file)"
  if [[ ! -f "$gs" ]]; then
    echo "Error: git-state.json not found at $gs. Run 'init' first." >&2
    exit 1
  fi
}

# Phase gate: block command unless current phase is one of the allowed phases.
# Usage: require_phase "allowed1" "allowed2" "next_step_hint"
# Last argument is always the hint; all preceding arguments are allowed phases.
require_phase() {
  local gs
  gs="$(git_state_file)"
  local current_phase
  current_phase=$(json_get "$gs" "phase")
  [[ -z "$current_phase" ]] && current_phase="init"

  local args=("$@")
  local last_idx=$(( ${#args[@]} - 1 ))
  local hint="${args[$last_idx]}"
  local allowed=("${args[@]:0:$last_idx}")

  for p in "${allowed[@]}"; do
    [[ "$current_phase" == "$p" ]] && return 0
  done

  cat <<ENDBLOCK
PHASE_BLOCKED
CURRENT_PHASE=${current_phase}
REQUIRED_PHASE=${allowed[*]}
NEXT_STEP=${hint}
ENDBLOCK
  exit 1
}

current_sha() {
  git rev-parse HEAD 2>/dev/null
}

cmd_scope_check() {
  local base_branch="main"
  local i=0
  while [[ $i -lt ${#EXTRA_ARGS[@]} ]]; do
    case "${EXTRA_ARGS[$i]}" in
      --base-branch)
        base_branch="${EXTRA_ARGS[$((i+1))]}"
        i=$((i+2))
        ;;
      *)
        echo "Error: Unknown scope-check option: ${EXTRA_ARGS[$i]}" >&2
        exit 1
        ;;
    esac
  done

  if [[ -z "$base_branch" || "$base_branch" == *".."* || "$base_branch" == -* ]]; then
    echo "Error: invalid base branch: ${base_branch}" >&2
    exit 1
  fi

  if ! git fetch --quiet origin "$base_branch"; then
    echo "Error: failed to fetch origin/${base_branch}" >&2
    exit 1
  fi

  local base_ref="origin/${base_branch}"
  if ! git rev-parse --verify --quiet "$base_ref" >/dev/null; then
    echo "Error: base ref not found after fetch: ${base_ref}" >&2
    exit 1
  fi

  local merge_base
  if ! merge_base="$(git merge-base "$base_ref" HEAD)"; then
    echo "Error: failed to compute merge-base between ${base_ref} and HEAD" >&2
    exit 1
  fi

  local files
  files="$(git diff --name-only "${merge_base}..HEAD")"

  local count
  if [[ -n "$files" ]]; then
    count="$(printf '%s\n' "$files" | sed '/^$/d' | wc -l | tr -d ' ')"
  else
    count=0
  fi

  cat <<ENDOUT
SCOPE_CHECK_OK
BASE_BRANCH=${base_branch}
BASE_REF=${base_ref}
MERGE_BASE=${merge_base}
IN_SCOPE_FILE_COUNT=${count}
IN_SCOPE_FILES_BEGIN
${files}
IN_SCOPE_FILES_END
ENDOUT
}

extract_markdown_verdict() {
  local file="$1"
  python3 - "$file" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text() if path.exists() else ""

patterns = [
    r"(?im)^\s*verdict\s*:\s*(PASS_WITH_WARNINGS|PASS|FAIL|REVIEW)\s*$",
    r"(?im)^\s*[-*]?\s*\*\*result\*\*\s*:\s*(PASS_WITH_WARNINGS|PASS|FAIL|REVIEW)\b",
    r"(?im)^\s*[-*]?\s*result\s*:\s*(PASS_WITH_WARNINGS|PASS|FAIL|REVIEW)\b",
    r"(?im)^\s*\*\*result\s*:\s*(PASS_WITH_WARNINGS|PASS|FAIL|REVIEW)\*\*",
    r"(?im)^\s*verdict\s*[:\-]\s*(PASS_WITH_WARNINGS|PASS|FAIL|REVIEW)\b",
]

for pattern in patterns:
    match = re.search(pattern, text)
    if match:
        print(match.group(1).upper())
        break
PY
}

# ============================================================================
# Command: read-config
# ============================================================================

cmd_read_config() {
  # Layer 1: defaults
  local max_spec_rounds="$DEFAULT_MAX_SPEC_ROUNDS"
  local max_eval_rounds="$DEFAULT_MAX_EVAL_ROUNDS"
  local cross_model_review="$DEFAULT_CROSS_MODEL_REVIEW"
  local cross_model_peer="$DEFAULT_CROSS_MODEL_PEER"
  local auto_retro="$DEFAULT_AUTO_RETRO"
  local claude_md_path="$DEFAULT_CLAUDE_MD_PATH"
  local max_verify_rounds="$DEFAULT_MAX_VERIFY_ROUNDS"
  local coverage_threshold="$DEFAULT_COVERAGE_THRESHOLD"
  local skip_full_verify="$DEFAULT_SKIP_FULL_VERIFY"
  local autonomous_pr="$DEFAULT_AUTONOMOUS_PR"

  # Layer 2: .harness/config.json
  local config_file=".harness/config.json"
  if [[ -f "$config_file" ]]; then
    local val
    val=$(json_get "$config_file" "max_spec_rounds") && [[ -n "$val" ]] && max_spec_rounds="$val"
    val=$(json_get "$config_file" "max_eval_rounds") && [[ -n "$val" ]] && max_eval_rounds="$val"
    val=$(json_get "$config_file" "cross_model_review") && [[ -n "$val" ]] && cross_model_review="$val"
    val=$(json_get "$config_file" "cross_model_peer") && [[ -n "$val" ]] && cross_model_peer="$val"
    val=$(json_get "$config_file" "auto_retro") && [[ -n "$val" ]] && auto_retro="$val"
    val=$(json_get "$config_file" "claude_md_path") && [[ -n "$val" ]] && claude_md_path="$val"
    val=$(json_get "$config_file" "max_verify_rounds") && [[ -n "$val" ]] && max_verify_rounds="$val"
    val=$(json_get "$config_file" "coverage_threshold") && [[ -n "$val" ]] && coverage_threshold="$val"
    val=$(json_get "$config_file" "skip_full_verify") && [[ -n "$val" ]] && skip_full_verify=$(echo "$val" | tr '[:upper:]' '[:lower:]')
    val=$(json_get "$config_file" "autonomous_pr") && [[ -n "$val" ]] && autonomous_pr=$(echo "$val" | tr '[:upper:]' '[:lower:]')
  fi

  # Layer 3: CLI args (via EXTRA_ARGS)
  # Schema fields: max_spec_rounds, max_eval_rounds, cross_model_review,
  # cross_model_peer, auto_retro, claude_md_path, max_verify_rounds,
  # coverage_threshold, skip_full_verify, autonomous_pr.
  local i=0
  while [[ $i -lt ${#EXTRA_ARGS[@]} ]]; do
    case "${EXTRA_ARGS[$i]}" in
      --max-spec-rounds)  max_spec_rounds="${EXTRA_ARGS[$((i+1))]}"; i=$((i+2)) ;;
      --max-eval-rounds)  max_eval_rounds="${EXTRA_ARGS[$((i+1))]}"; i=$((i+2)) ;;
      --cross-model-review) cross_model_review="${EXTRA_ARGS[$((i+1))]}"; i=$((i+2)) ;;
      --cross-model-peer) cross_model_peer="${EXTRA_ARGS[$((i+1))]}"; i=$((i+2)) ;;
      --auto-retro)       auto_retro="${EXTRA_ARGS[$((i+1))]}"; i=$((i+2)) ;;
      --claude-md-path)   claude_md_path="${EXTRA_ARGS[$((i+1))]}"; i=$((i+2)) ;;
      --max-verify-rounds) max_verify_rounds="${EXTRA_ARGS[$((i+1))]}"; i=$((i+2)) ;;
      --coverage-threshold) coverage_threshold="${EXTRA_ARGS[$((i+1))]}"; i=$((i+2)) ;;
      --skip-full-verify) skip_full_verify="${EXTRA_ARGS[$((i+1))]}"; i=$((i+2)) ;;
      --autonomous-pr) autonomous_pr="$(echo "${EXTRA_ARGS[$((i+1))]}" | tr '[:upper:]' '[:lower:]')"; i=$((i+2)) ;;
      *) echo "Error: Unknown config option: ${EXTRA_ARGS[$i]}" >&2; exit 1 ;;
    esac
  done

  cat <<ENDCONFIG
CONFIG_OK
MAX_SPEC_ROUNDS=${max_spec_rounds}
MAX_EVAL_ROUNDS=${max_eval_rounds}
CROSS_MODEL_REVIEW=${cross_model_review}
CROSS_MODEL_PEER=${cross_model_peer}
AUTO_RETRO=${auto_retro}
CLAUDE_MD_PATH=${claude_md_path}
MAX_VERIFY_ROUNDS=${max_verify_rounds}
COVERAGE_THRESHOLD=${coverage_threshold}
SKIP_FULL_VERIFY=${skip_full_verify}
AUTONOMOUS_PR=${autonomous_pr}
ENDCONFIG
}

# ============================================================================
# Command: init
# ============================================================================

cmd_init() {
  require_task_id

  # ── Step 1: Gitignore FIRST — must be committed before any .harness/ files ──
  local gitignore=".gitignore"
  local entries=(
    ".harness/*/"
    "!.harness/retro/"
    "!.harness/retro/**"
    "!.harness/config.json"
  )
  local gitignore_changed=false
  for entry in "${entries[@]}"; do
    grep -qxF "$entry" "$gitignore" 2>/dev/null || {
      echo "$entry" >> "$gitignore"
      gitignore_changed=true
    }
  done

  # Commit gitignore if changed — this commit survives any future git reset --hard
  if [[ "$gitignore_changed" == "true" ]]; then
    git add "$gitignore"
    if ! git commit -m "chore: gitignore harness task directories" 2>/dev/null; then
      echo "Error: Failed to commit .gitignore update. Check git identity and hooks." >&2
      echo "Hint: Run 'git config user.name' and 'git config user.email' to verify." >&2
      exit 1
    fi
  fi

  # ── Step 2: Create directory tree (idempotent) ──
  local dir
  dir="$(harness_dir)"
  local gs
  gs="$(git_state_file)"

  mkdir -p "$dir/spec-review"
  mkdir -p "$dir/checkpoints"
  mkdir -p "$dir/e2e"
  mkdir -p ".harness/retro"

  # ── Step 3: Initialize git-state.json (task_start_sha is AFTER gitignore commit) ──
  if [[ ! -f "$gs" ]]; then
    local sha
    sha="$(current_sha)"
    cat > "$gs" <<ENDJSON
{
  "task_id": "${TASK_ID}",
  "task_start_sha": "${sha}",
  "phase": "init",
  "checkpoints": {},
  "e2e_baseline_sha": "",
  "e2e_final_sha": "",
  "review_loop_status": "",
  "review_loop_session_id": "",
  "review_loop_summary_file": "",
  "review_loop_rounds_file": "",
  "full_verify_baseline_sha": "",
  "full_verify_final_sha": "",
  "full_verify_status": "",
  "pr_url": ""
}
ENDJSON
  fi

  cat <<ENDOUT
INIT_OK
TASK_ID=${TASK_ID}
TASK_DIR=${dir}
GIT_STATE=${gs}
TASK_START_SHA=$(json_get "$gs" "task_start_sha")
ENDOUT
}

# ============================================================================
# Command: status
# ============================================================================

cmd_status() {
  require_task_id
  require_git_state

  local gs
  gs="$(git_state_file)"
  local dir
  dir="$(harness_dir)"

  # Determine spec status
  local spec_status="unknown"
  if [[ -f "$dir/spec.md" ]]; then
    spec_status=$(grep -m1 '^status:' "$dir/spec.md" 2>/dev/null | sed 's/status:[[:space:]]*//' || echo "unknown")
  fi

  # Count checkpoints and find last completed
  local total_checkpoints=0
  local last_completed=""
  local next_checkpoint=""

  if [[ -f "$gs" ]]; then
    total_checkpoints=$(json_count_checkpoints "$gs")

    # Find last completed (has final_sha) and next pending, skipping aborted
    for cp in $(json_list_checkpoints "$gs"); do
      local aborted
      aborted=$(json_get_nested "$gs" "checkpoints.${cp}.aborted")
      # Skip aborted checkpoints — they are terminal
      if [[ "$aborted" == "True" ]]; then
        continue
      fi
      local final
      final=$(json_get_nested "$gs" "checkpoints.${cp}.final_sha")
      if [[ -n "$final" ]]; then
        last_completed="$cp"
      elif [[ -z "$next_checkpoint" ]]; then
        next_checkpoint="$cp"
      fi
    done
  fi

  # Read explicit phase from git-state.json (v0.4.0+), fall back to derived phase
  local phase
  phase=$(json_get "$gs" "phase")

  if [[ -z "$phase" ]]; then
    # Legacy fallback for pre-v0.4.0 git-state.json without phase field
    local e2e_base
    e2e_base=$(json_get_nested "$gs" "e2e_baseline_sha")
    local e2e_final
    e2e_final=$(json_get_nested "$gs" "e2e_final_sha")

    if [[ -n "$e2e_final" ]]; then
      phase="e2e"
    elif [[ -n "$e2e_base" ]]; then
      phase="checkpoints"
    elif [[ -n "$last_completed" || -n "$next_checkpoint" ]]; then
      phase="checkpoints"
    else
      phase="init"
    fi
  fi

  # Count total checkpoints from spec (not just started ones)
  local spec_checkpoints=0
  if [[ -f "$dir/spec.md" ]]; then
    spec_checkpoints=$(grep -c '^### Checkpoint [0-9]' "$dir/spec.md" 2>/dev/null || echo 0)
  fi

  cat <<ENDOUT
STATUS_OK
TASK_ID=${TASK_ID}
PHASE=${phase}
SPEC_STATUS=${spec_status}
LAST_COMPLETED_CHECKPOINT=${last_completed:-none}
NEXT_CHECKPOINT=${next_checkpoint:-none}
STARTED_CHECKPOINTS=${total_checkpoints}
SPEC_CHECKPOINTS=${spec_checkpoints}
ENDOUT
}

# ============================================================================
# Command: discover
# ============================================================================

cmd_discover() {
  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  local matches=()

  for spec in .harness/*/spec.md; do
    [[ -f "$spec" ]] || continue

    # Check status: approved
    local status
    status=$(grep -m1 '^status:' "$spec" 2>/dev/null | sed 's/status:[[:space:]]*//')
    [[ "$status" == "approved" ]] || continue

    # Check branch matches
    local branch
    branch=$(grep -m1 '^branch:' "$spec" 2>/dev/null | sed 's/branch:[[:space:]]*//')
    if [[ -n "$branch" && "$branch" != "$current_branch" ]]; then
      continue
    fi

    local task_id
    task_id=$(grep -m1 '^task_id:' "$spec" 2>/dev/null | sed 's/task_id:[[:space:]]*//')
    local title
    title=$(grep -m1 '^title:' "$spec" 2>/dev/null | sed 's/title:[[:space:]]*//')

    matches+=("${task_id}|${title}|${spec}")
  done

  echo "DISCOVER_OK"
  echo "MATCH_COUNT=${#matches[@]}"
  echo "BRANCH=${current_branch}"
  for m in "${matches[@]}"; do
    echo "MATCH=${m}"
  done
}

# ============================================================================
# Command: begin-checkpoint
# ============================================================================

cmd_begin_checkpoint() {
  require_task_id
  require_checkpoint
  require_git_state

  # Phase gate: only allow begin-checkpoint while in init or checkpoints.
  # Prevents starting a new checkpoint after the task has advanced to e2e or beyond.
  require_phase "init" "checkpoints" "Task has advanced past the checkpoint phase. Start a new task instead of re-running begin-checkpoint."

  local gs
  gs="$(git_state_file)"

  # Reject begin-checkpoint once E2E has begun (e2e_baseline_sha recorded) and
  # before E2E completes. Prevents checkpoint work from overlapping E2E.
  local gs_e2e_baseline gs_e2e_final
  gs_e2e_baseline=$(json_get "$gs" "e2e_baseline_sha")
  gs_e2e_final=$(json_get "$gs" "e2e_final_sha")
  if [[ -n "$gs_e2e_baseline" && -z "$gs_e2e_final" ]]; then
    echo "Error: E2E is in progress (e2e_baseline_sha=${gs_e2e_baseline}). Complete E2E (\$ENGINE pass-e2e) before starting new checkpoints, or abort the task." >&2
    exit 1
  fi

  # Validate: checkpoint must not already have final_sha or be aborted
  local existing_final
  existing_final=$(json_get_nested "$gs" "checkpoints.${CHECKPOINT}.final_sha")
  if [[ -n "$existing_final" ]]; then
    echo "Error: Checkpoint ${CHECKPOINT} already completed (final_sha: ${existing_final})" >&2
    exit 1
  fi
  local existing_aborted
  existing_aborted=$(json_get_nested "$gs" "checkpoints.${CHECKPOINT}.aborted")
  if [[ "$existing_aborted" == "True" ]]; then
    echo "Error: Checkpoint ${CHECKPOINT} was aborted. Use a new checkpoint number." >&2
    exit 1
  fi
  # Reject re-begin on already-started checkpoint (baseline is immutable)
  local existing_baseline
  existing_baseline=$(json_get_nested "$gs" "checkpoints.${CHECKPOINT}.baseline_sha")
  if [[ -n "$existing_baseline" ]]; then
    echo "Error: Checkpoint ${CHECKPOINT} already started (baseline_sha: ${existing_baseline}). Cannot re-begin." >&2
    exit 1
  fi

  local sha
  sha="$(current_sha)"

  # Record baseline_sha
  local tmp
  tmp=$(mktemp)
  python3 -c "
import json, sys
filepath, cp_id, sha_val, outpath = sys.argv[1:5]
with open(filepath) as f:
    data = json.load(f)
cp = data.setdefault('checkpoints', {}).setdefault(cp_id, {})
cp['baseline_sha'] = sha_val
cp.setdefault('iterations', {})
with open(outpath, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
" "$gs" "$CHECKPOINT" "$sha" "$tmp" && mv "$tmp" "$gs" || { rm -f "$tmp"; exit 1; }

  # Set phase to checkpoints (idempotent — stays checkpoints for subsequent checkpoints)
  json_set "$gs" "phase" "checkpoints"

  # Create directory structure
  local cp_dir
  cp_dir="$(harness_dir)/checkpoints/${CHECKPOINT}"
  mkdir -p "${cp_dir}/iter-1/evidence"

  cat <<ENDOUT
BEGIN_CHECKPOINT_OK
TASK_ID=${TASK_ID}
CHECKPOINT=${CHECKPOINT}
BASELINE_SHA=${sha}
CHECKPOINT_DIR=${cp_dir}
ENDOUT
}

# ============================================================================
# Command: end-iteration
# ============================================================================

cmd_end_iteration() {
  require_task_id
  require_checkpoint
  require_git_state

  local gs
  gs="$(git_state_file)"

  # Auto-detect iteration if not specified
  if [[ -z "$ITERATION" ]]; then
    ITERATION=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
iters = data.get('checkpoints', {}).get(sys.argv[2], {}).get('iterations', {})
if not iters:
    print(1)
else:
    print(max(int(k) for k in iters.keys()) + 1)
" "$gs" "$CHECKPOINT") || ITERATION=1
    [[ -z "$ITERATION" ]] && ITERATION=1
  fi

  local sha
  sha="$(current_sha)"

  # Check for empty iteration (warn, don't error)
  local baseline
  baseline=$(json_get_nested "$gs" "checkpoints.${CHECKPOINT}.baseline_sha")
  if [[ -n "$baseline" && "$sha" == "$baseline" ]]; then
    echo "Warning: Empty iteration — HEAD is still at baseline SHA" >&2
  fi

  # Record end_sha
  json_add_iteration "$gs" "$CHECKPOINT" "$ITERATION" "$sha"

  # Pre-create next iteration directory
  local next_iter=$((ITERATION + 1))
  local next_dir
  next_dir="$(harness_dir)/checkpoints/${CHECKPOINT}/iter-${next_iter}/evidence"
  mkdir -p "$next_dir"

  cat <<ENDOUT
END_ITERATION_OK
TASK_ID=${TASK_ID}
CHECKPOINT=${CHECKPOINT}
ITERATION=${ITERATION}
END_SHA=${sha}
NEXT_ITER_DIR=$(harness_dir)/checkpoints/${CHECKPOINT}/iter-${next_iter}
ENDOUT
}

# ============================================================================
# Command: pass-checkpoint
# ============================================================================

cmd_pass_checkpoint() {
  require_task_id
  require_checkpoint
  require_git_state

  local gs
  gs="$(git_state_file)"

  local sha
  sha="$(current_sha)"

  # Count iterations
  local iter_count
  iter_count=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(len(data.get('checkpoints', {}).get(sys.argv[2], {}).get('iterations', {})))
" "$gs" "$CHECKPOINT")

  if [[ "$iter_count" -le 0 ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=checkpoint ${CHECKPOINT} has no recorded iterations" >&2
    echo "NEXT_STEP=Run: \$ENGINE end-iteration --task-id ${TASK_ID} --checkpoint ${CHECKPOINT}" >&2
    exit 1
  fi

  local cp_dir
  cp_dir="$(harness_dir)/checkpoints/${CHECKPOINT}"
  local last_iter
  last_iter=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
iters = data.get('checkpoints', {}).get(sys.argv[2], {}).get('iterations', {})
print(max((int(k) for k in iters.keys()), default=0))
" "$gs" "$CHECKPOINT")

  local last_eval="${cp_dir}/iter-${last_iter}/evaluation.md"
  local output_summary="${cp_dir}/iter-${last_iter}/output-summary.md"
  local evaluator_session_file="${cp_dir}/iter-${last_iter}/evaluator-session-id.txt"

  if [[ ! -f "$output_summary" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=${output_summary} not found" >&2
    echo "NEXT_STEP=Write the Generator output summary before passing checkpoint ${CHECKPOINT}" >&2
    exit 1
  fi

  if [[ ! -f "$last_eval" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=${last_eval} not found" >&2
    echo "NEXT_STEP=Run the harness-evaluator and write evaluation.md before passing checkpoint ${CHECKPOINT}" >&2
    exit 1
  fi

  local eval_verdict
  eval_verdict=$(extract_markdown_verdict "$last_eval")
  if [[ -z "$eval_verdict" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=${last_eval} missing verdict/result field" >&2
    echo "NEXT_STEP=Evaluator must write verdict: PASS|FAIL|REVIEW in evaluation.md frontmatter or Verdict section" >&2
    exit 1
  fi

  if [[ "$eval_verdict" != "PASS" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=${last_eval} verdict is ${eval_verdict}; checkpoint pass requires PASS" >&2
    echo "NEXT_STEP=Send evaluation feedback to the Generator, fix, end a new iteration, and re-evaluate" >&2
    exit 1
  fi

  if [[ ! -f "$evaluator_session_file" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=${evaluator_session_file} not found" >&2
    echo "NEXT_STEP=Invoke the harness-evaluator agent with --session-id-file before passing checkpoint ${CHECKPOINT}" >&2
    exit 1
  fi

  local evaluator_session_id
  evaluator_session_id=$(tr -d '[:space:]' < "$evaluator_session_file")
  if [[ -z "$evaluator_session_id" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=${evaluator_session_file} is empty" >&2
    echo "NEXT_STEP=Re-run the harness-evaluator agent and capture its session id" >&2
    exit 1
  fi

  local reused_checkpoint
  reused_checkpoint=$(python3 - "$gs" "$CHECKPOINT" "$evaluator_session_id" <<'PY'
import json
import sys

state_path, current_cp, session_id = sys.argv[1:4]
with open(state_path) as f:
    data = json.load(f)

for cp_id, cp in sorted(data.get("checkpoints", {}).items()):
    if cp_id == current_cp:
        continue
    if cp.get("evaluator_session_id") == session_id:
        print(cp_id)
        break
PY
)
  if [[ -n "$reused_checkpoint" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=evaluator session ${evaluator_session_id} was already used for checkpoint ${reused_checkpoint}" >&2
    echo "NEXT_STEP=Spawn a fresh harness-evaluator agent for checkpoint ${CHECKPOINT}" >&2
    exit 1
  fi

  # Record final_sha only after the evaluator gate passes.
  local tmp
  tmp=$(mktemp)
  python3 -c "
import json, sys
filepath, cp_id, sha_val, eval_file, session_id, session_file, outpath = sys.argv[1:8]
with open(filepath) as f:
    data = json.load(f)
cp = data['checkpoints'][cp_id]
cp['final_sha'] = sha_val
cp['final_evaluation'] = eval_file
cp['evaluator_session_id'] = session_id
cp['evaluator_session_file'] = session_file
with open(outpath, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
" "$gs" "$CHECKPOINT" "$sha" "$last_eval" "$evaluator_session_id" "$evaluator_session_file" "$tmp" && mv "$tmp" "$gs" || { rm -f "$tmp"; exit 1; }

  # Write status.md
  cat > "${cp_dir}/status.md" <<ENDSTATUS
---
checkpoint: ${CHECKPOINT}
result: PASS
total_iterations: ${iter_count}
final_evaluation: ${last_eval}
evaluator_session_id: ${evaluator_session_id}
---

## Summary

Checkpoint ${CHECKPOINT} passed after ${iter_count} iteration(s).

## Iteration History

$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
iters = data.get('checkpoints', {}).get(sys.argv[2], {}).get('iterations', {})
print('| Iter | End SHA |')
print('|------|---------|')
for k in sorted(iters.keys(), key=int):
    sha = iters[k].get('end_sha', 'N/A')[:7]
    print(f'| {k} | {sha} |')
" "$gs" "$CHECKPOINT")
ENDSTATUS

  cat <<ENDOUT
PASS_CHECKPOINT_OK
TASK_ID=${TASK_ID}
CHECKPOINT=${CHECKPOINT}
FINAL_SHA=${sha}
TOTAL_ITERATIONS=${iter_count}
STATUS_FILE=${cp_dir}/status.md
ENDOUT
}

# ============================================================================
# Command: begin-e2e
# ============================================================================

cmd_begin_e2e() {
  require_task_id
  require_git_state

  # Phase gate: E2E can only begin after at least one checkpoint has passed.
  require_phase "checkpoints" "Run: \$ENGINE pass-checkpoint --task-id ${TASK_ID} --checkpoint <id> before begin-e2e"

  local gs
  gs="$(git_state_file)"

  # Reject re-begin once an E2E baseline already exists (baseline is immutable per task).
  local existing_e2e_baseline
  existing_e2e_baseline=$(json_get "$gs" "e2e_baseline_sha")
  if [[ -n "$existing_e2e_baseline" ]]; then
    echo "Error: begin-e2e already called (e2e_baseline_sha: ${existing_e2e_baseline}). Cannot re-begin." >&2
    exit 1
  fi

  # Require every non-aborted checkpoint to have final_sha before E2E can begin.
  local pending_cps
  pending_cps=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
pending = []
for cp_id, cp in (data.get('checkpoints') or {}).items():
    if str(cp.get('aborted', '')).lower() == 'true':
        continue
    if not cp.get('final_sha'):
        pending.append(cp_id)
print(','.join(sorted(pending)))
" "$gs")
  if [[ -n "$pending_cps" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=checkpoint(s) not yet passed: ${pending_cps}" >&2
    echo "NEXT_STEP=Run: \$ENGINE pass-checkpoint --task-id ${TASK_ID} --checkpoint <id> for each pending checkpoint, or abort them" >&2
    exit 1
  fi

  local sha
  sha="$(current_sha)"

  json_set "$gs" "e2e_baseline_sha" "$sha"

  local e2e_dir
  e2e_dir="$(harness_dir)/e2e"
  mkdir -p "${e2e_dir}/iter-1/evidence"

  cat <<ENDOUT
BEGIN_E2E_OK
TASK_ID=${TASK_ID}
E2E_BASELINE_SHA=${sha}
E2E_DIR=${e2e_dir}
ENDOUT
}

# ============================================================================
# Command: pass-e2e
# ============================================================================

cmd_pass_e2e() {
  require_task_id
  require_git_state

  # Phase gate: pass-e2e requires a prior begin-e2e (phase still "checkpoints",
  # e2e_baseline_sha recorded). Blocks pass-e2e without begin-e2e.
  require_phase "checkpoints" "Run: \$ENGINE begin-e2e --task-id ${TASK_ID} before pass-e2e"

  local gs
  gs="$(git_state_file)"

  local existing_e2e_baseline
  existing_e2e_baseline=$(json_get "$gs" "e2e_baseline_sha")
  if [[ -z "$existing_e2e_baseline" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=e2e_baseline_sha not recorded — begin-e2e was never called for this task" >&2
    echo "NEXT_STEP=Run: \$ENGINE begin-e2e --task-id ${TASK_ID}" >&2
    exit 1
  fi

  local sha
  sha="$(current_sha)"

  local e2e_dir
  e2e_dir="$(harness_dir)/e2e"

  local e2e_report
  e2e_report=$(find "${e2e_dir}" -path "*/iter-*/e2e-report.md" -type f 2>/dev/null | sort -V | tail -1)

  if [[ -z "$e2e_report" ]] || [[ ! -f "$e2e_report" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=${e2e_dir}/iter-N/e2e-report.md not found" >&2
    echo "NEXT_STEP=Run the E2E evaluator and write e2e-report.md before passing E2E" >&2
    exit 1
  fi

  local e2e_verdict
  e2e_verdict=$(extract_markdown_verdict "$e2e_report")
  if [[ -z "$e2e_verdict" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=${e2e_report} missing verdict field" >&2
    echo "NEXT_STEP=E2E evaluator must write verdict: PASS|FAIL|REVIEW in e2e-report.md frontmatter or Verdict section" >&2
    exit 1
  fi

  if [[ "$e2e_verdict" != "PASS" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=${e2e_report} verdict is ${e2e_verdict}; E2E pass requires PASS" >&2
    echo "NEXT_STEP=Fix cross-checkpoint integration issues, re-run E2E, and produce a PASS report" >&2
    exit 1
  fi

  json_set "$gs" "e2e_final_sha" "$sha"
  json_set "$gs" "phase" "e2e"

  # Write e2e status.md
  cat > "${e2e_dir}/status.md" <<ENDSTATUS
---
result: PASS
e2e_baseline_sha: $(json_get "$gs" "e2e_baseline_sha")
e2e_final_sha: ${sha}
final_evaluation: ${e2e_report}
---

## Summary

E2E verification passed. All cross-checkpoint integration checks confirmed.
ENDSTATUS

  cat <<ENDOUT
PASS_E2E_OK
TASK_ID=${TASK_ID}
E2E_FINAL_SHA=${sha}
STATUS_FILE=${e2e_dir}/status.md
ENDOUT
}

# ============================================================================
# Command: pass-review-loop
# ============================================================================

cmd_pass_review_loop() {
  require_task_id
  require_git_state
  require_phase "e2e" "Run: \$ENGINE pass-e2e --task-id ${TASK_ID}"

  # Verify review-loop artifacts exist and belong to this task
  local summary_file=".review-loop/latest/summary.md"
  local rounds_file=".review-loop/latest/rounds.json"

  if [[ ! -f "$summary_file" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=.review-loop/latest/summary.md not found" >&2
    echo "NEXT_STEP=Run review-loop first. The skill produces summary.md upon completion." >&2
    exit 1
  fi

  if [[ ! -f "$rounds_file" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=.review-loop/latest/rounds.json not found" >&2
    echo "NEXT_STEP=Run review-loop first. The skill produces rounds.json upon completion." >&2
    exit 1
  fi

  # Verify artifacts are newer than E2E pass (prevents stale artifacts from prior tasks)
  local gs
  gs="$(git_state_file)"
  local e2e_final_sha
  e2e_final_sha=$(json_get "$gs" "e2e_final_sha")
  if [[ -n "$e2e_final_sha" ]]; then
    local e2e_ts summary_ts
    e2e_ts=$(git log -1 --format=%ct "$e2e_final_sha" 2>/dev/null || echo 0)
    summary_ts=$(stat -f %m "$summary_file" 2>/dev/null || stat -c %Y "$summary_file" 2>/dev/null || echo 0)
    if [[ "$summary_ts" -lt "$e2e_ts" ]]; then
      echo "PHASE_BLOCKED" >&2
      echo "REASON=.review-loop/latest/summary.md is older than E2E pass — likely from a previous task" >&2
      echo "NEXT_STEP=Run review-loop for the current task. Stale artifacts from prior sessions are not accepted." >&2
      exit 1
    fi
  fi

  local rl_status rl_rounds rl_session
  rl_status=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(data.get('session', {}).get('status', ''))
" "$rounds_file")
  rl_rounds=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(data.get('session', {}).get('total_rounds', ''))
" "$rounds_file")
  rl_session=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(data.get('session', {}).get('id', ''))
" "$rounds_file")

  if [[ -z "$rl_status" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=.review-loop/latest/rounds.json missing session.status" >&2
    echo "NEXT_STEP=Run review-loop to completion before passing review-loop" >&2
    exit 1
  fi

  local normalized_status
  normalized_status=$(echo "$rl_status" | tr '[:upper:]' '[:lower:]')
  if [[ "$normalized_status" != "consensus" && "$normalized_status" != "read_only_complete" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=review-loop session ${rl_session:-unknown} status is ${rl_status}; expected consensus or read_only_complete" >&2
    echo "NEXT_STEP=Resolve review-loop findings until consensus, or escalate if the session ended without consensus" >&2
    exit 1
  fi

  if [[ ! "$rl_rounds" =~ ^[0-9]+$ || "$rl_rounds" -lt 1 ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=review-loop session ${rl_session:-unknown} has total_rounds=${rl_rounds:-missing}" >&2
    echo "NEXT_STEP=Run at least one peer-review round before passing review-loop" >&2
    exit 1
  fi

  local gs
  gs="$(git_state_file)"
  json_set "$gs" "phase" "review-loop"
  json_set "$gs" "review_loop_status" "COMPLETE"
  json_set "$gs" "review_loop_session_id" "$rl_session"
  json_set "$gs" "review_loop_summary_file" "$summary_file"
  json_set "$gs" "review_loop_rounds_file" "$rounds_file"

  cat <<ENDOUT
PASS_REVIEW_LOOP_OK
TASK_ID=${TASK_ID}
PHASE=review-loop
SESSION_ID=${rl_session}
SUMMARY_FILE=${summary_file}
ROUNDS_FILE=${rounds_file}
ENDOUT
}

# ============================================================================
# Command: skip-review-loop
# ============================================================================

cmd_skip_review_loop() {
  require_task_id
  require_git_state
  require_phase "e2e" "Run: \$ENGINE pass-e2e --task-id ${TASK_ID}"

  # Read config to verify cross_model_review is disabled
  # json_get returns Python's "True"/"False" for JSON booleans, so normalize to lowercase
  local cross_model_review="true"
  local config_file=".harness/config.json"
  if [[ -f "$config_file" ]]; then
    local val
    val=$(json_get "$config_file" "cross_model_review")
    [[ -n "$val" ]] && cross_model_review=$(echo "$val" | tr '[:upper:]' '[:lower:]')
  fi

  if [[ "$cross_model_review" == "true" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=cross_model_review is true in config — cannot skip review-loop" >&2
    echo "NEXT_STEP=Either run review-loop, or set cross_model_review=false in .harness/config.json" >&2
    exit 1
  fi

  local gs
  gs="$(git_state_file)"
  json_set "$gs" "phase" "review-loop"
  json_set "$gs" "review_loop_status" "SKIPPED"

  cat <<ENDOUT
SKIP_REVIEW_LOOP_OK
TASK_ID=${TASK_ID}
PHASE=review-loop
REASON=cross_model_review=false in config
ENDOUT
}

# ============================================================================
# Command: begin-full-verify
# ============================================================================

cmd_begin_full_verify() {
  require_task_id
  require_git_state
  require_phase "review-loop" "Run: \$ENGINE pass-review-loop --task-id ${TASK_ID} (or skip-review-loop)"

  local gs
  gs="$(git_state_file)"

  local sha
  sha="$(current_sha)"

  json_set "$gs" "full_verify_baseline_sha" "$sha"
  json_set "$gs" "full_verify_started_at" "$(date +%s)"
  json_set "$gs" "phase" "full-verify"

  local fv_dir
  fv_dir="$(harness_dir)/full-verify"
  mkdir -p "$fv_dir"

  cat <<ENDOUT
BEGIN_FULL_VERIFY_OK
TASK_ID=${TASK_ID}
FULL_VERIFY_BASELINE_SHA=${sha}
FULL_VERIFY_DIR=${fv_dir}
ENDOUT
}

# ============================================================================
# Command: pass-full-verify
# ============================================================================

cmd_pass_full_verify() {
  require_task_id
  require_git_state
  require_phase "full-verify" "Run: \$ENGINE begin-full-verify --task-id ${TASK_ID}"

  local fv_dir
  fv_dir="$(harness_dir)/full-verify"

  # Find the latest verification-report.md inside iter-* directories (protocol path),
  # falling back to full-verify/verification-report.md for backwards compat.
  local report
  report=$(find "${fv_dir}" -path "*/iter-*/verification-report.md" -type f 2>/dev/null | sort -V | tail -1)
  if [[ -z "$report" ]] && [[ -f "${fv_dir}/verification-report.md" ]]; then
    report="${fv_dir}/verification-report.md"
  fi

  if [[ -z "$report" ]] || [[ ! -f "$report" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=full-verify/verification-report.md not found" >&2
    echo "NEXT_STEP=Create verification-report.md with verdict: PASS or PASS_WITH_WARNINGS in ${fv_dir}/iter-N/" >&2
    exit 1
  fi

  # Verify report is newer than begin-full-verify start time (prevents stale artifacts)
  local gs_file
  gs_file="$(git_state_file)"
  local started_at
  started_at=$(json_get "$gs_file" "full_verify_started_at")
  if [[ -n "$started_at" && "$started_at" != "0" ]]; then
    local report_ts
    report_ts=$(stat -f %m "$report" 2>/dev/null || stat -c %Y "$report" 2>/dev/null || echo 0)
    if [[ "$report_ts" -le "$started_at" ]]; then
      echo "PHASE_BLOCKED" >&2
      echo "REASON=verification-report.md is older than begin-full-verify — likely from a previous run" >&2
      echo "NEXT_STEP=Re-run full-verify evaluation to produce a fresh report" >&2
      exit 1
    fi
  fi

  # Extract verdict from frontmatter
  local verdict
  verdict=$(grep -m1 '^verdict:' "$report" 2>/dev/null | sed 's/verdict:[[:space:]]*//')

  if [[ -z "$verdict" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=verification-report.md missing verdict: field" >&2
    echo "NEXT_STEP=Add verdict: PASS (or PASS_WITH_WARNINGS) to the frontmatter of verification-report.md" >&2
    exit 1
  fi

  if [[ "$verdict" != "PASS" && "$verdict" != "PASS_WITH_WARNINGS" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=verification-report.md verdict is '${verdict}' — must be PASS or PASS_WITH_WARNINGS" >&2
    echo "NEXT_STEP=Fix failing checks and re-run full-verify evaluation" >&2
    exit 1
  fi

  # ── Coverage gate: enforce threshold for backend/infra/fullstack tasks ──
  local spec_file
  spec_file="$(harness_dir)/spec.md"
  local has_backend_work="false"
  if [[ -f "$spec_file" ]]; then
    if grep -qi 'Type.*backend\|Type.*infrastructure\|Type.*fullstack' "$spec_file"; then
      has_backend_work="true"
    fi
  fi

  if [[ "$has_backend_work" == "true" ]]; then
    # Read coverage_threshold from config (default 85)
    local threshold="$DEFAULT_COVERAGE_THRESHOLD"
    local config_file=".harness/config.json"
    if [[ -f "$config_file" ]]; then
      local cfg_val
      cfg_val=$(json_get "$config_file" "coverage_threshold")
      [[ -n "$cfg_val" ]] && threshold="$cfg_val"
    fi

    # Parse coverage_percent from verification-report.md frontmatter
    local coverage
    coverage=$(grep -m1 '^coverage_percent:' "$report" 2>/dev/null | sed 's/coverage_percent:[[:space:]]*//' | tr -d '%')

    if [[ -z "$coverage" ]]; then
      echo "PHASE_BLOCKED" >&2
      echo "REASON=Backend/infra/fullstack work detected but verification-report.md missing coverage_percent field" >&2
      echo "NEXT_STEP=Re-run full-verify with coverage reporting enabled. Add coverage_percent: <N> to frontmatter." >&2
      exit 1
    fi

    # Integer comparison (truncate decimals)
    local cov_int=${coverage%%.*}
    if [[ "$cov_int" -lt "$threshold" ]]; then
      echo "PHASE_BLOCKED" >&2
      echo "REASON=Test coverage ${coverage}% is below threshold ${threshold}% (backend/infra/fullstack work requires >= ${threshold}%)" >&2
      echo "NEXT_STEP=Add tests to increase coverage to >= ${threshold}%, then re-run full-verify" >&2
      exit 1
    fi
  fi
  # ── End coverage gate ──

  local gs
  gs="$(git_state_file)"
  local sha
  sha="$(current_sha)"

  json_set "$gs" "full_verify_final_sha" "$sha"
  json_set "$gs" "full_verify_status" "COMPLETE"
  # Phase stays full-verify (pass means full-verify is complete, PR can proceed)

  cat <<ENDOUT
PASS_FULL_VERIFY_OK
TASK_ID=${TASK_ID}
FULL_VERIFY_FINAL_SHA=${sha}
VERDICT=${verdict}
ENDOUT
}

# ============================================================================
# Command: skip-full-verify
# ============================================================================

cmd_skip_full_verify() {
  require_task_id
  require_git_state
  require_phase "review-loop" "Run: \$ENGINE pass-review-loop --task-id ${TASK_ID} (or skip-review-loop)"

  # Read config to verify skip_full_verify is enabled
  local skip_full_verify="false"
  local config_file=".harness/config.json"
  if [[ -f "$config_file" ]]; then
    local val
    val=$(json_get "$config_file" "skip_full_verify")
    [[ -n "$val" ]] && skip_full_verify=$(echo "$val" | tr '[:upper:]' '[:lower:]')
  fi

  if [[ "$skip_full_verify" != "true" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=skip_full_verify is not true in config — cannot skip full-verify" >&2
    echo "NEXT_STEP=Either run full-verify, or set skip_full_verify=true in .harness/config.json" >&2
    exit 1
  fi

  local gs
  gs="$(git_state_file)"
  json_set "$gs" "phase" "full-verify"
  json_set "$gs" "full_verify_status" "SKIPPED"

  cat <<ENDOUT
SKIP_FULL_VERIFY_OK
TASK_ID=${TASK_ID}
PHASE=full-verify
REASON=skip_full_verify=true in config
ENDOUT
}

# ============================================================================
# Command: create-pr
# ============================================================================

cmd_create_pr() {
  require_task_id
  require_git_state
  require_phase "full-verify" "Run: \$ENGINE pass-full-verify --task-id ${TASK_ID} (or skip-full-verify)"

  local gs_check
  gs_check="$(git_state_file)"
  local fv_status
  fv_status=$(json_get "$gs_check" "full_verify_status")
  if [[ "$fv_status" != "COMPLETE" && "$fv_status" != "SKIPPED" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=full_verify_status is '${fv_status}' — full-verify must complete before PR creation" >&2
    echo "NEXT_STEP=Run: \$ENGINE pass-full-verify --task-id ${TASK_ID} (or skip-full-verify)" >&2
    exit 1
  fi

  local autonomous_pr="$DEFAULT_AUTONOMOUS_PR"
  local config_file=".harness/config.json"
  if [[ -f "$config_file" ]]; then
    local val
    val=$(json_get "$config_file" "autonomous_pr")
    [[ -n "$val" ]] && autonomous_pr=$(echo "$val" | tr '[:upper:]' '[:lower:]')
  fi

  local base_branch="main"
  local title="${TASK_ID}"
  local body="Harness task ${TASK_ID}"
  local i=0
  while [[ $i -lt ${#EXTRA_ARGS[@]} ]]; do
    case "${EXTRA_ARGS[$i]}" in
      --base)  base_branch="${EXTRA_ARGS[$((i+1))]}"; i=$((i+2)) ;;
      --title) title="${EXTRA_ARGS[$((i+1))]}"; i=$((i+2)) ;;
      --body)  body="${EXTRA_ARGS[$((i+1))]}"; i=$((i+2)) ;;
      *) echo "Error: Unknown create-pr option: ${EXTRA_ARGS[$i]}" >&2; exit 1 ;;
    esac
  done

  local head_branch
  head_branch="$(git rev-parse --abbrev-ref HEAD)"
  local dir
  dir="$(harness_dir)"
  mkdir -p "$dir"

  local body_file="${dir}/pr-body.md"
  printf '%s\n' "$body" > "$body_file"

  if [[ "$autonomous_pr" == "false" ]]; then
    local handoff="${dir}/pr-handoff.md"
    if [[ -f "$handoff" ]]; then
      echo "Warning: pr-handoff.md exists; overwriting" >&2
    fi
    cat > "$handoff" <<ENDHANDOFF
# PR Handoff

Title: ${title}

Body:

${body}

Base branch: ${base_branch}
Head branch: ${head_branch}

Commands:

\`\`\`bash
git push -u origin HEAD
gh pr create --base "${base_branch}" --head "${head_branch}" --title "${title}" --body-file "${body_file}"
\`\`\`
ENDHANDOFF

    cat <<ENDOUT
PR_HANDOFF_OK
TASK_ID=${TASK_ID}
AUTONOMOUS_PR=false
HANDOFF_FILE=${handoff}
BODY_FILE=${body_file}
NEXT_STEP=Create the PR manually, then run: \$ENGINE pass-pr --task-id ${TASK_ID} --pr-url <url>
ENDOUT
    return 0
  fi

  if [[ "$autonomous_pr" != "true" ]]; then
    echo "Error: autonomous_pr must be true or false, got '${autonomous_pr}'" >&2
    exit 1
  fi

  if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI is required when autonomous_pr=true" >&2
    exit 1
  fi

  local pr_url
  if ! git push -u origin HEAD >&2; then
    echo "Error: git push -u origin HEAD failed" >&2
    exit 1
  fi

  if ! pr_url="$(gh pr create --base "$base_branch" --head "$head_branch" --title "$title" --body-file "$body_file")"; then
    echo "Error: gh pr create failed" >&2
    exit 1
  fi

  cat <<ENDOUT
CREATE_PR_OK
TASK_ID=${TASK_ID}
AUTONOMOUS_PR=true
PR_URL=${pr_url}
NEXT_STEP=Run: \$ENGINE pass-pr --task-id ${TASK_ID} --pr-url ${pr_url}
ENDOUT
}

# ============================================================================
# Command: pass-pr
# ============================================================================

cmd_pass_pr() {
  require_task_id
  require_git_state
  require_phase "full-verify" "Run: \$ENGINE pass-full-verify --task-id ${TASK_ID} (or skip-full-verify)"

  # Verify full-verify actually completed (not just started)
  local gs_check
  gs_check="$(git_state_file)"
  local fv_status
  fv_status=$(json_get "$gs_check" "full_verify_status")
  if [[ "$fv_status" != "COMPLETE" && "$fv_status" != "SKIPPED" ]]; then
    echo "PHASE_BLOCKED" >&2
    echo "REASON=full_verify_status is '${fv_status}' — full-verify must complete before PR" >&2
    echo "NEXT_STEP=Run: \$ENGINE pass-full-verify --task-id ${TASK_ID} (or skip-full-verify)" >&2
    exit 1
  fi

  # Extract --pr-url from EXTRA_ARGS
  local pr_url=""
  local i=0
  while [[ $i -lt ${#EXTRA_ARGS[@]} ]]; do
    case "${EXTRA_ARGS[$i]}" in
      --pr-url) pr_url="${EXTRA_ARGS[$((i+1))]}"; i=$((i+2)) ;;
      *) i=$((i+1)) ;;
    esac
  done

  if [[ -z "$pr_url" ]]; then
    echo "Error: --pr-url is required (e.g., --pr-url https://github.com/org/repo/pull/123)" >&2
    exit 1
  fi

  local gs
  gs="$(git_state_file)"
  json_set "$gs" "phase" "pr"
  json_set "$gs" "pr_url" "$pr_url"

  cat <<ENDOUT
PASS_PR_OK
TASK_ID=${TASK_ID}
PHASE=pr
PR_URL=${pr_url}
ENDOUT
}

# ============================================================================
# Command: complete
# ============================================================================

cmd_complete() {
  require_task_id
  require_git_state
  require_phase "retro" "Run: \$ENGINE assemble-retro-input --task-id ${TASK_ID}"

  local gs
  gs="$(git_state_file)"
  json_set "$gs" "phase" "done"

  cat <<ENDOUT
COMPLETE_OK
TASK_ID=${TASK_ID}
PHASE=done
ENDOUT
}

# ============================================================================
# Command: abort
# ============================================================================

cmd_abort() {
  require_task_id
  require_git_state

  local gs
  gs="$(git_state_file)"

  # Auto-detect active checkpoint: has baseline_sha but no final_sha AND not aborted
  local active_cp=""
  local baseline_sha=""

  if [[ -n "$CHECKPOINT" ]]; then
    # Validate: cannot abort a completed or already-aborted checkpoint
    local explicit_final
    explicit_final=$(json_get_nested "$gs" "checkpoints.${CHECKPOINT}.final_sha")
    if [[ -n "$explicit_final" ]]; then
      echo "Error: Checkpoint ${CHECKPOINT} already completed (final_sha: ${explicit_final}). Cannot abort." >&2
      exit 1
    fi
    local explicit_aborted
    explicit_aborted=$(json_get_nested "$gs" "checkpoints.${CHECKPOINT}.aborted")
    if [[ "$explicit_aborted" == "True" ]]; then
      echo "Error: Checkpoint ${CHECKPOINT} already aborted." >&2
      exit 1
    fi
    active_cp="$CHECKPOINT"
    baseline_sha=$(json_get_nested "$gs" "checkpoints.${CHECKPOINT}.baseline_sha")
  else
    for cp in $(json_list_checkpoints "$gs"); do
      local aborted
      aborted=$(json_get_nested "$gs" "checkpoints.${cp}.aborted")
      # Skip aborted checkpoints — they are terminal
      if [[ "$aborted" == "True" ]]; then
        continue
      fi
      local final
      final=$(json_get_nested "$gs" "checkpoints.${cp}.final_sha")
      if [[ -z "$final" ]]; then
        active_cp="$cp"
        baseline_sha=$(json_get_nested "$gs" "checkpoints.${cp}.baseline_sha")
        break
      fi
    done
  fi

  if [[ -z "$active_cp" ]]; then
    echo "Error: No active checkpoint found to abort" >&2
    exit 1
  fi

  if [[ -z "$baseline_sha" ]]; then
    echo "Error: No baseline_sha for checkpoint ${active_cp}" >&2
    exit 1
  fi

  # Safety: verify SHA exists
  if ! git rev-parse --verify "$baseline_sha" &>/dev/null; then
    echo "Error: baseline_sha ${baseline_sha} does not exist in git history" >&2
    exit 1
  fi

  # Safety: check for uncommitted changes outside harness scope
  local dirty
  dirty=$(git status --porcelain -- ':!.harness' 2>/dev/null | head -5)
  if [[ -n "$dirty" ]]; then
    echo "Warning: Uncommitted changes detected outside .harness/:" >&2
    echo "$dirty" >&2
    echo "These will be lost by git reset --hard. Stashing first." >&2
    git stash push -m "harness-abort-safety: pre-abort stash" -- ':!.harness' 2>/dev/null || true
  fi

  # Reset to baseline
  git reset --hard "$baseline_sha"

  # Mark checkpoint as aborted and reset phase to checkpoints
  local tmp_abort
  tmp_abort=$(mktemp)
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
cp = data.get('checkpoints', {}).get(sys.argv[2], {})
cp['aborted'] = True
cp['final_sha'] = ''
data['phase'] = 'checkpoints'
with open(sys.argv[3], 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
" "$gs" "$active_cp" "$tmp_abort" && mv "$tmp_abort" "$gs"

  # Write status.md = ABORTED
  local cp_dir
  cp_dir="$(harness_dir)/checkpoints/${active_cp}"
  mkdir -p "$cp_dir"

  local iter_count
  iter_count=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(len(data.get('checkpoints', {}).get(sys.argv[2], {}).get('iterations', {})))
" "$gs" "$active_cp") || iter_count=0

  cat > "${cp_dir}/status.md" <<ENDSTATUS
---
checkpoint: ${active_cp}
result: ABORTED
total_iterations: ${iter_count:-0}
---

## Summary

Checkpoint ${active_cp} aborted. Reset to baseline SHA ${baseline_sha:0:7}.
ENDSTATUS

  cat <<ENDOUT
ABORT_OK
TASK_ID=${TASK_ID}
CHECKPOINT=${active_cp}
BASELINE_SHA=${baseline_sha}
RESET_TO=${baseline_sha:0:7}
ENDOUT
}

# ============================================================================
# Command: assemble-context
# ============================================================================

cmd_assemble_context() {
  require_task_id
  require_checkpoint
  require_git_state

  local dir
  dir="$(harness_dir)"
  local gs
  gs="$(git_state_file)"
  local spec="$dir/spec.md"

  if [[ ! -f "$spec" ]]; then
    echo "Error: spec.md not found at $spec" >&2
    exit 1
  fi

  # Extract checkpoint section from spec, ignoring markdown-looking headings in
  # fenced code blocks.
  local cp_num_int
  cp_num_int=$(echo "$CHECKPOINT" | sed 's/^0*//')
  local checkpoint_section
  checkpoint_section=$(python3 -c "
import re, sys
spec_path = sys.argv[1]
cp_num = sys.argv[2]
with open(spec_path) as f:
    lines = f.read().splitlines()
fence_re = re.compile(r'^\s*' + chr(96) + r'{3,}')

start = None
start_re = re.compile(r'^### Checkpoint 0*' + re.escape(cp_num) + r':')
for idx, line in enumerate(lines):
    if start_re.match(line):
        start = idx
        break

if start is None:
    print('ERROR: Could not extract checkpoint section')
    sys.exit(1)

end = len(lines)
in_fence = False
for idx in range(start + 1, len(lines)):
    line = lines[idx]
    if fence_re.match(line):
        in_fence = not in_fence
    if in_fence:
        continue
    if re.match(r'^### Checkpoint [0-9]', line) or re.match(r'^## [^#]', line) or re.match(r'^---\s*$', line):
        end = idx
        break

print('\n'.join(lines[start:end]).strip())
" "$spec" "$cp_num_int")

  if [[ $? -ne 0 || "$checkpoint_section" == ERROR:* ]]; then
    echo "Error: Failed to extract checkpoint ${CHECKPOINT} from spec.md" >&2
    echo "Hint: Ensure spec uses '### Checkpoint NN:' delimiters" >&2
    exit 1
  fi

  # Detect checkpoint type from the real checkpoint section only. Accept the
  # canonical '- Type:' form and one bold-decorated '- **Type**:' compatibility
  # form, but fail loudly instead of emitting checkpoint_type: unknown.
  local checkpoint_type
  checkpoint_type=$(python3 -c "
import re, sys
spec_path, cp_num, checkpoint = sys.argv[1:4]
with open(spec_path) as f:
    lines = f.read().splitlines()
fence_re = re.compile(r'^\s*' + chr(96) + r'{3,}')

start = None
start_re = re.compile(r'^### Checkpoint 0*' + re.escape(cp_num) + r':')
for idx, line in enumerate(lines):
    if start_re.match(line):
        start = idx
        break

end = len(lines)
in_fence = False
for idx in range((start or 0) + 1, len(lines)):
    line = lines[idx]
    if fence_re.match(line):
        in_fence = not in_fence
    if in_fence:
        continue
    if re.match(r'^### Checkpoint [0-9]', line) or re.match(r'^## [^#]', line) or re.match(r'^---\s*$', line):
        end = idx
        break

type_line = None
invalid_line = None
valid = {'frontend', 'backend', 'fullstack', 'infrastructure'}
in_fence = False
for idx in range(start or 0, end):
    line = lines[idx]
    if fence_re.match(line):
        in_fence = not in_fence
        continue
    if in_fence:
        continue
    match = re.match(r'^\s*-\s*(?:\*\*)?Type(?:\*\*)?\s*:\s*([A-Za-z_-]+)\b', line)
    if match:
        value = match.group(1).lower()
        if value in valid:
            type_line = value
            break
        invalid_line = idx + 1

if type_line:
    print(type_line)
else:
    line_no = invalid_line or ((start or 0) + 1)
    print(f'Error: checkpoint {checkpoint} missing or invalid Type field at {spec_path}:{line_no}', file=sys.stderr)
    sys.exit(1)
" "$spec" "$cp_num_int" "$CHECKPOINT") || exit 1

  # Build Prior Progress from completed checkpoint status.md files
  local prior_progress=""
  for cp in $(json_list_checkpoints "$gs"); do
    [[ "$cp" == "$CHECKPOINT" ]] && break
    local status_file="$dir/checkpoints/${cp}/status.md"
    if [[ -f "$status_file" ]]; then
      local result
      result=$(grep -m1 '^result:' "$status_file" | sed 's/result:[[:space:]]*//')
      local summary
      summary=$(sed -n '/^## Summary/,/^##/p' "$status_file" | head -5 | tail -4)
      prior_progress="${prior_progress}
### Checkpoint ${cp}: ${result}
${summary}
"
    fi
  done

  # Extract Scope (objective) from checkpoint section
  local scope_objective
  scope_objective=$(echo "$checkpoint_section" | python3 -c "
import re, sys
text = sys.stdin.read()
match = re.search(r'\*\*Scope\*\*:\s*(.+)', text)
if match:
    print(match.group(1).strip())
else:
    # Fallback: use checkpoint title
    title = re.search(r'### Checkpoint \d+:\s*(.+)', text)
    print(title.group(1).strip() if title else 'See checkpoint section above')
")

  # Extract Effort estimate from checkpoint section
  local effort_estimate
  effort_estimate=$(echo "$checkpoint_section" | grep -i 'Effort estimate' | sed 's/.*:\s*//' | tr -d '* ' | head -1)
  effort_estimate="${effort_estimate:-M}"  # default to M if not specified

  # Extract Constraints from spec (## Constraints or ## Technical Approach section)
  local constraints
  constraints=$(python3 -c "
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
for header in ['## Constraints', '## Technical Approach']:
    pattern = f'({re.escape(header)}.*?)(?=## [^#]|\Z)'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        print(match.group(1).strip())
        break
" "$spec")

  # Write context.md
  local cp_dir
  cp_dir="$dir/checkpoints/${CHECKPOINT}"
  mkdir -p "$cp_dir"

  cat > "${cp_dir}/context.md" <<ENDCONTEXT
---
task_id: ${TASK_ID}
checkpoint: ${CHECKPOINT}
checkpoint_type: ${checkpoint_type}
effort_estimate: ${effort_estimate}
---

## Objective

${checkpoint_section}

## ⛔ SCOPE CONSTRAINT

Your sole objective is: **${scope_objective}**

Every modification must directly serve this objective.
Judgment rule: if removing a modification does not affect achievement of this objective, that modification should not exist.

You MAY modify files beyond "Files of interest" if necessary to achieve the objective.
You MAY create new files if necessary to achieve the objective.
You MUST NOT make improvements, refactoring, or optimizations unrelated to this objective.
Unrelated improvements go in output-summary.md under "Recommended Follow-up".

**Effort estimate: ${effort_estimate}** — if your changes significantly exceed this estimate, ensure every modification is goal-relevant.

## Prior Progress

${prior_progress:-No prior checkpoints completed.}

## Constraints

${constraints:-No explicit constraints in spec.}

## Files of Interest

(Determined from checkpoint scope above — these are reference, not a constraint)
ENDCONTEXT

  cat <<ENDOUT
ASSEMBLE_CONTEXT_OK
TASK_ID=${TASK_ID}
CHECKPOINT=${CHECKPOINT}
CHECKPOINT_TYPE=${checkpoint_type}
EFFORT_ESTIMATE=${effort_estimate}
CONTEXT_FILE=${cp_dir}/context.md
ENDOUT
}

# ============================================================================
# Command: assemble-retro-input
# ============================================================================

cmd_assemble_retro_input() {
  require_task_id
  require_git_state
  require_phase "pr" "retro" "Run: \$ENGINE pass-pr --task-id ${TASK_ID} --pr-url <url>"

  # Set phase to retro
  json_set "$(git_state_file)" "phase" "retro"

  local dir
  dir="$(harness_dir)"
  local gs
  gs="$(git_state_file)"

  # Aggregate metrics from all checkpoints
  local metrics
  metrics=$(python3 -c "
import json, subprocess, sys
with open(sys.argv[1]) as f:
    data = json.load(f)

cps = data.get('checkpoints', {})
total = len(cps)
passed_first = 0
total_iters = 0

for cp_id, cp in sorted(cps.items()):
    iters = cp.get('iterations', {})
    n = len(iters)
    total_iters += n
    if n <= 1 and cp.get('final_sha'):
        passed_first += 1

avg = total_iters / total if total > 0 else 0

start_sha = data.get('task_start_sha', 'HEAD~50')
try:
    result = subprocess.run(['git', 'log', '--oneline', f'{start_sha}..HEAD'],
                          capture_output=True, text=True)
    commits = len([l for l in result.stdout.strip().split('\n') if l])
except Exception:
    commits = 0

try:
    result = subprocess.run(['git', 'log', '--oneline', '--grep=revert', '-i', f'{start_sha}..HEAD'],
                          capture_output=True, text=True)
    reverts = len([l for l in result.stdout.strip().split('\n') if l])
except Exception:
    reverts = 0

print(f'TOTAL={total}')
print(f'PASSED_FIRST={passed_first}')
print(f'TOTAL_ITERS={total_iters}')
print(f'AVG_ITERS={avg:.1f}')
print(f'COMMITS={commits}')
print(f'REVERTS={reverts}')
" "$gs")

  # Collect Rule Conflict Notes from all output-summary.md files
  local rule_conflicts=""
  for summary in "$dir"/checkpoints/*/iter-*/output-summary.md; do
    [[ -f "$summary" ]] || continue
    local conflicts
    conflicts=$(sed -n '/## Rule Conflict Notes/,/^##/p' "$summary" 2>/dev/null | head -20 | tail -19)
    if [[ -n "$conflicts" && "$conflicts" != *"none"* && "$conflicts" != *"empty"* ]]; then
      rule_conflicts="${rule_conflicts}
### From ${summary}
${conflicts}
"
    fi
  done

  # Per-checkpoint summary table
  local cp_table
  cp_table=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
cps = data.get('checkpoints', {})
print('| Checkpoint | Iterations | Final SHA | Status |')
print('|------------|-----------|-----------|--------|')
for cp_id in sorted(cps.keys()):
    cp = cps[cp_id]
    iters = len(cp.get('iterations', {}))
    final = cp.get('final_sha', '')[:7] or 'N/A'
    if cp.get('aborted'):
        status = 'ABORTED'
    elif cp.get('final_sha'):
        status = 'PASS'
    else:
        status = 'IN PROGRESS'
    print(f'| {cp_id} | {iters} | {final} | {status} |')
" "$gs")

  # Spec title
  local task_title=""
  if [[ -f "$dir/spec.md" ]]; then
    task_title=$(grep -m1 '^title:' "$dir/spec.md" | sed 's/title:[[:space:]]*//')
  fi

  # E2E result
  local e2e_result="NOT_RUN"
  if [[ -f "$dir/e2e/status.md" ]]; then
    e2e_result=$(grep -m1 '^result:' "$dir/e2e/status.md" | sed 's/result:[[:space:]]*//')
  fi

  # Write retro-input.md
  cat > "$dir/retro-input.md" <<ENDRETRO
---
task_id: ${TASK_ID}
task_title: ${task_title}
---

## Task Metrics

$(echo "$metrics" | sed 's/^/- /')

## Per-Checkpoint Summary

${cp_table}

## All Rule Conflict Notes

${rule_conflicts:-No rule conflicts recorded.}

## E2E Result

${e2e_result}

## Git Activity

$(echo "$metrics" | grep -E '^(COMMITS|REVERTS)' | sed 's/^/- /')
ENDRETRO

  cat <<ENDOUT
ASSEMBLE_RETRO_INPUT_OK
TASK_ID=${TASK_ID}
RETRO_INPUT_FILE=${dir}/retro-input.md
$(echo "$metrics")
ENDOUT
}

# ============================================================================
# Command: validate-transition
# ============================================================================

cmd_validate_transition() {
  require_task_id
  require_git_state

  local target="${EXTRA_ARGS[0]:-}"
  if [[ -z "$target" ]]; then
    echo "Error: Target state required as argument (e.g., begin-checkpoint)" >&2
    exit 1
  fi

  local gs
  gs="$(git_state_file)"

  # Abort is always allowed
  if [[ "$target" == "abort" ]]; then
    echo "TRANSITION_OK"
    echo "TARGET=${target}"
    echo "REASON=abort always allowed"
    return 0
  fi

  # Determine current state
  local current_state="init"
  local has_checkpoints
  has_checkpoints=$(json_count_checkpoints "$gs")

  if [[ "$has_checkpoints" -gt 0 ]]; then
    # Check if any checkpoint is active (baseline_sha but no final_sha AND not aborted)
    local has_active="false"
    local all_passed="true"
    for cp in $(json_list_checkpoints "$gs"); do
      local final
      final=$(json_get_nested "$gs" "checkpoints.${cp}.final_sha")
      local baseline
      baseline=$(json_get_nested "$gs" "checkpoints.${cp}.baseline_sha")
      local aborted
      aborted=$(json_get_nested "$gs" "checkpoints.${cp}.aborted")
      # Skip aborted checkpoints — they are terminal
      if [[ "$aborted" == "True" ]]; then
        continue
      fi
      if [[ -n "$baseline" && -z "$final" ]]; then
        has_active="true"
        local iter_count
        iter_count=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(len(data.get('checkpoints',{}).get(sys.argv[2],{}).get('iterations',{})))
" "$gs" "$cp")
        if [[ "$iter_count" -gt 0 ]]; then
          current_state="post-iteration"
        else
          current_state="post-begin-checkpoint"
        fi
      fi
      if [[ -z "$final" ]]; then
        all_passed="false"
      fi
    done

    if [[ "$has_active" == "false" ]]; then
      local e2e_base
      e2e_base=$(json_get_nested "$gs" "e2e_baseline_sha")
      local e2e_final
      e2e_final=$(json_get_nested "$gs" "e2e_final_sha")

      # For begin-e2e, also check spec checkpoint count vs completed count
      local dir
      dir="$(harness_dir)"
      local spec_checkpoints=0
      if [[ -f "$dir/spec.md" ]]; then
        spec_checkpoints=$(grep -c '^### Checkpoint [0-9]' "$dir/spec.md" 2>/dev/null || echo 0)
      fi
      local completed_count
      completed_count=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
cps = data.get('checkpoints', {})
count = sum(1 for cp in cps.values() if cp.get('final_sha') and not cp.get('aborted'))
print(count)
" "$gs")

      if [[ -n "$e2e_final" ]]; then
        current_state="post-e2e"
      elif [[ -n "$e2e_base" ]]; then
        current_state="in-e2e"
      elif [[ "$all_passed" == "true" && "$spec_checkpoints" -gt 0 && "$completed_count" -ge "$spec_checkpoints" ]]; then
        current_state="all-checkpoints-passed"
      elif [[ "$all_passed" == "true" && "$spec_checkpoints" -eq 0 ]]; then
        # No spec to validate against — trust started checkpoint state
        current_state="all-checkpoints-passed"
      else
        current_state="between-checkpoints"
      fi
    fi
  fi

  # Read phase from git-state.json (v0.4.0+)
  local phase
  phase=$(json_get "$gs" "phase")
  [[ -z "$phase" ]] && phase="init"

  # Transition rules
  local valid="false"
  local reason=""
  case "$target" in
    begin-checkpoint)
      if [[ "$current_state" == "init" || "$current_state" == "between-checkpoints" || "$current_state" == "all-checkpoints-passed" ]]; then
        valid="true"
      else
        reason="Cannot begin checkpoint from state: ${current_state}. Must complete current checkpoint first."
      fi
      ;;
    end-iteration)
      if [[ "$current_state" == "post-begin-checkpoint" || "$current_state" == "post-iteration" ]]; then
        valid="true"
      else
        reason="Cannot end iteration from state: ${current_state}. Must begin a checkpoint first."
      fi
      ;;
    pass-checkpoint)
      if [[ "$current_state" == "post-iteration" ]]; then
        valid="true"
      else
        reason="Cannot pass checkpoint from state: ${current_state}. Must have at least one iteration."
      fi
      ;;
    begin-e2e)
      if [[ "$current_state" == "all-checkpoints-passed" ]]; then
        valid="true"
      else
        reason="Cannot begin E2E from state: ${current_state}. All checkpoints must pass first."
      fi
      ;;
    pass-e2e)
      if [[ "$current_state" == "in-e2e" ]]; then
        valid="true"
      else
        reason="Cannot pass E2E from state: ${current_state}. Must begin E2E first."
      fi
      ;;
    pass-review-loop|skip-review-loop)
      if [[ "$phase" == "e2e" ]]; then
        valid="true"
      else
        reason="Cannot pass/skip review-loop from phase: ${phase}. E2E must pass first."
      fi
      ;;
    begin-full-verify)
      if [[ "$phase" == "review-loop" ]]; then
        valid="true"
      else
        reason="Cannot begin full-verify from phase: ${phase}. Review-loop must complete first."
      fi
      ;;
    pass-full-verify)
      if [[ "$phase" == "full-verify" ]]; then
        valid="true"
      else
        reason="Cannot pass full-verify from phase: ${phase}. Full-verify must be active."
      fi
      ;;
    skip-full-verify)
      if [[ "$phase" == "review-loop" ]]; then
        valid="true"
      else
        reason="Cannot skip full-verify from phase: ${phase}. Review-loop must complete first."
      fi
      ;;
    create-pr)
      if [[ "$phase" == "full-verify" ]]; then
        local fv_status
        fv_status=$(json_get "$gs" "full_verify_status")
        if [[ "$fv_status" == "COMPLETE" || "$fv_status" == "SKIPPED" ]]; then
          valid="true"
        else
          reason="Cannot create PR: full_verify_status is '${fv_status}' — full-verify must complete first."
        fi
      else
        reason="Cannot create PR from phase: ${phase}. Full-verify must complete first."
      fi
      ;;
    pass-pr)
      if [[ "$phase" == "full-verify" ]]; then
        local fv_status
        fv_status=$(json_get "$gs" "full_verify_status")
        if [[ "$fv_status" == "COMPLETE" || "$fv_status" == "SKIPPED" ]]; then
          valid="true"
        else
          reason="Cannot pass PR: full_verify_status is '${fv_status}' — full-verify must complete first."
        fi
      else
        reason="Cannot pass PR from phase: ${phase}. Full-verify must complete first."
      fi
      ;;
    assemble-retro-input)
      if [[ "$phase" == "pr" || "$phase" == "retro" ]]; then
        valid="true"
      else
        reason="Cannot assemble retro input from phase: ${phase}. PR must be created first."
      fi
      ;;
    complete)
      if [[ "$phase" == "retro" ]]; then
        valid="true"
      else
        reason="Cannot complete from phase: ${phase}. Retro must run first."
      fi
      ;;
    *)
      reason="Unknown transition target: ${target}"
      ;;
  esac

  if [[ "$valid" == "true" ]]; then
    echo "TRANSITION_OK"
    echo "CURRENT_STATE=${current_state}"
    echo "TARGET=${target}"
  else
    echo "TRANSITION_DENIED"
    echo "CURRENT_STATE=${current_state}"
    echo "TARGET=${target}"
    echo "REASON=${reason}"
    return 1
  fi
}

# ============================================================================
# Main Dispatch
# ============================================================================

parse_args "$@"

case "$COMMAND" in
  read-config)          cmd_read_config ;;
  init)                 cmd_init ;;
  status)               cmd_status ;;
  discover)             cmd_discover ;;
  begin-checkpoint)     cmd_begin_checkpoint ;;
  end-iteration)        cmd_end_iteration ;;
  pass-checkpoint)      cmd_pass_checkpoint ;;
  begin-e2e)            cmd_begin_e2e ;;
  pass-e2e)             cmd_pass_e2e ;;
  pass-review-loop)     cmd_pass_review_loop ;;
  skip-review-loop)     cmd_skip_review_loop ;;
  begin-full-verify)    cmd_begin_full_verify ;;
  pass-full-verify)     cmd_pass_full_verify ;;
  skip-full-verify)     cmd_skip_full_verify ;;
  create-pr)            cmd_create_pr ;;
  pass-pr)              cmd_pass_pr ;;
  complete)             cmd_complete ;;
  abort)                cmd_abort ;;
  assemble-context)     cmd_assemble_context ;;
  assemble-retro-input) cmd_assemble_retro_input ;;
  scope-check)          cmd_scope_check ;;
  validate-transition)  cmd_validate_transition ;;
  --help)               usage ;;
  *)
    echo "Error: Unknown command: $COMMAND" >&2
    echo "Run with --help for usage." >&2
    exit 1
    ;;
esac
