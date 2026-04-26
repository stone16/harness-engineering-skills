#!/usr/bin/env bash
set -uo pipefail

TMP_BODIES=()
cleanup_tmp_bodies() {
  if ((${#TMP_BODIES[@]})); then
    rm -f "${TMP_BODIES[@]}"
  fi
}
trap cleanup_tmp_bodies EXIT INT TERM

sanitize_line() {
  printf '%s' "$1" | tr '\r\n' '  '
}

RAW_TARGET_REPO="$(sanitize_line "${TARGET_REPO-}")"
TARGET_REPO="$(printf '%s' "${RAW_TARGET_REPO:-__missing__}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
PROPOSAL_INDEX="$(sanitize_line "${PROPOSAL_INDEX:?Set proposal number}")"
TITLE="$(sanitize_line "${TITLE:?Set per-proposal issue title}")"
: "${BODY_FILE:?Set per-proposal body file path}"
: "${FILED_ISSUES_FILE:?Set retro index file path for Filed Issues updates}"
HARNESS_TARGET_REPO="${HARNESS_TARGET_REPO:-stone16/harness-engineering-skills}"
[[ -r "$BODY_FILE" ]] || {
  echo "BODY_FILE not readable: $BODY_FILE" >&2
  exit 1
}

ensure_filed_issues_section() {
  grep -qxF '## Filed Issues' "$FILED_ISSUES_FILE" 2>/dev/null && return 0
  if [[ -s "$FILED_ISSUES_FILE" ]]; then
    printf '\n## Filed Issues\n' >> "$FILED_ISSUES_FILE" || return 1
  else
    printf '## Filed Issues\n' >> "$FILED_ISSUES_FILE" || return 1
  fi
}

record_filed_issue() {
  ensure_filed_issues_section || {
    echo "Unable to ensure Filed Issues section in $FILED_ISSUES_FILE" >&2
    exit 1
  }
  printf '%s\n' "$1" >> "$FILED_ISSUES_FILE" || {
    echo "Unable to write Filed Issues record to $FILED_ISSUES_FILE" >&2
    exit 1
  }
}

ensure_host_target_repo() {
  HOST_TARGET_REPO="${HOST_TARGET_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
  if [[ -z "$HOST_TARGET_REPO" ]]; then
    return 1
  fi
}

ensure_label() {
  local target="$1"
  if [[ "$target" == "harness" ]]; then
    gh label view "harness-retro" --repo "$HARNESS_TARGET_REPO" >/dev/null 2>&1 ||
      gh label create "harness-retro" --repo "$HARNESS_TARGET_REPO" --color "5319e7" --description "Harness retro follow-up" >/dev/null 2>&1 ||
      gh label view "harness-retro" --repo "$HARNESS_TARGET_REPO" >/dev/null 2>&1
  else
    gh label view "harness-retro" --repo "$HOST_TARGET_REPO" >/dev/null 2>&1 ||
      gh label create "harness-retro" --repo "$HOST_TARGET_REPO" --color "5319e7" --description "Harness retro follow-up" >/dev/null 2>&1 ||
      gh label view "harness-retro" --repo "$HOST_TARGET_REPO" >/dev/null 2>&1
  fi
}

create_issue() {
  local target="$1"
  local label_ready="$2"
  local repo
  local args

  [[ "$target" == "harness" ]] && repo="$HARNESS_TARGET_REPO" || repo="$HOST_TARGET_REPO"
  args=(--repo "$repo" --title "$TITLE" --body-file "$BODY_FILE")
  [[ "$label_ready" == "true" ]] && args+=(--label "harness-retro")
  gh issue create "${args[@]}"
}

file_single_repo_issue() {
  local target="$1"
  local url label_ready label_note
  label_ready="false"
  ensure_label "$target" && label_ready="true"
  url="$(create_issue "$target" "$label_ready")" || url=""
  if [[ -z "$url" ]]; then
    record_filed_issue "- Proposal $PROPOSAL_INDEX (skipped, $target create failed): $TITLE"
    return 0
  fi
  label_note=""
  [[ "$label_ready" != "true" ]] && label_note=", label not applied"
  record_filed_issue "- Proposal $PROPOSAL_INDEX ($target$label_note): $url"
}

annotate_partial_cross_file() {
  local url="$1"
  local missing_target="$2"
  local body
  body="$(mktemp "${TMPDIR:-/tmp}/harness-retro-body.XXXXXX" 2>/dev/null)" || return 0
  TMP_BODIES+=("$body")
  printf '%s\nCross-filed: pending - %s create failed; see retro index proposal %s.\n' "$(cat "$BODY_FILE")" "$missing_target" "$PROPOSAL_INDEX" > "$body"
  gh issue edit "$url" --body-file "$body" >/dev/null 2>&1 || true
  rm -f "$body"
}

file_harness_when_host_unresolved() {
  local harness_url harness_label label_note
  harness_label="false"
  ensure_label harness && harness_label="true"
  harness_url="$(create_issue harness "$harness_label")" || harness_url=""
  if [[ -z "$harness_url" ]]; then
    record_filed_issue "- Proposal $PROPOSAL_INDEX (both, host repo unresolved, harness create failed): no-harness-url | no-host-url"
    return 0
  fi
  label_note=""
  [[ "$harness_label" != "true" ]] && label_note=", labels harness=false"
  record_filed_issue "- Proposal $PROPOSAL_INDEX (both$label_note, host repo unresolved): $harness_url | no-host-url"
}

file_cross_repo_issue() {
  local host_url harness_url harness_body host_body harness_edit host_edit host_label harness_label label_note
  host_label="false"
  harness_label="false"
  ensure_label host && host_label="true"
  ensure_label harness && harness_label="true"
  host_url="$(create_issue host "$host_label")" || host_url=""
  harness_url="$(create_issue harness "$harness_label")" || harness_url=""
  label_note=""
  [[ "$harness_label" != "true" || "$host_label" != "true" ]] && label_note=", labels harness=$harness_label host=$host_label"

  if [[ -z "$host_url" || -z "$harness_url" ]]; then
    [[ -n "$host_url" ]] && annotate_partial_cross_file "$host_url" "harness"
    [[ -n "$harness_url" ]] && annotate_partial_cross_file "$harness_url" "host"
    record_filed_issue "- Proposal $PROPOSAL_INDEX (both$label_note, partial create): ${harness_url:-no-harness-url} | ${host_url:-no-host-url}"
    return 0
  fi

  harness_body="$(mktemp "${TMPDIR:-/tmp}/harness-retro-body.XXXXXX" 2>/dev/null)" || {
    record_filed_issue "- Proposal $PROPOSAL_INDEX (both, cross-link skipped, mktemp failed): $harness_url | $host_url"
    return 0
  }
  TMP_BODIES+=("$harness_body")
  host_body="$(mktemp "${TMPDIR:-/tmp}/harness-retro-body.XXXXXX" 2>/dev/null)" || {
    rm -f "$harness_body"
    record_filed_issue "- Proposal $PROPOSAL_INDEX (both, cross-link skipped, mktemp failed): $harness_url | $host_url"
    return 0
  }
  TMP_BODIES+=("$host_body")
  printf '%s\nCross-filed: %s\n' "$(cat "$BODY_FILE")" "$host_url" > "$harness_body"
  printf '%s\nCross-filed: %s\n' "$(cat "$BODY_FILE")" "$harness_url" > "$host_body"

  harness_edit=ok
  host_edit=ok
  gh issue edit "$harness_url" --body-file "$harness_body" >/dev/null 2>&1 || harness_edit=failed
  gh issue edit "$host_url" --body-file "$host_body" >/dev/null 2>&1 || host_edit=failed
  rm -f "$harness_body" "$host_body"

  if [[ "$harness_edit" != "ok" || "$host_edit" != "ok" ]]; then
    record_filed_issue "- Proposal $PROPOSAL_INDEX (both$label_note, partial edit harness=$harness_edit host=$host_edit): $harness_url | $host_url"
  else
    record_filed_issue "- Proposal $PROPOSAL_INDEX (both$label_note): $harness_url | $host_url"
  fi
}

file_retro_issue() {
  command -v gh >/dev/null || { record_filed_issue "- Proposal $PROPOSAL_INDEX (skipped): gh CLI unavailable"; return 0; }

  case "$TARGET_REPO" in
    host)
      if ensure_host_target_repo; then
        file_single_repo_issue "$TARGET_REPO"
      else
        record_filed_issue "- Proposal $PROPOSAL_INDEX (skipped, host repo unresolved): $TITLE"
      fi
      ;;
    harness) file_single_repo_issue "$TARGET_REPO" ;;
    both)
      if ensure_host_target_repo; then
        file_cross_repo_issue
      else
        file_harness_when_host_unresolved
      fi
      ;;
    *) record_filed_issue "- Proposal $PROPOSAL_INDEX (skipped, invalid target_repo='$RAW_TARGET_REPO'): $TITLE" ;;
  esac
}

file_retro_issue
