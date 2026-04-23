---
name: review-loop
version: 1.4.0
description: |
  Cross-LLM iterative code review loop. Spawns a peer reviewer (Codex, Claude, or Gemini CLI)
  to review code changes, then iterates until both agents agree on the final code state.
  Code gets modified during the loop — the final output is improved code + consensus report.

  Use when: "review loop", "peer review", "cross review", "review with codex",
  "review with claude", "review with gemini", "让 codex review", "让 claude review",
  "交叉 review", "peer review 这段代码", "code review loop", "iterative review"
---

# Review Loop — Cross-LLM Iterative Code Review

Spawns a peer reviewer (Codex, Claude, or Gemini) to independently review your code changes.
The host agent evaluates findings, implements accepted fixes, and re-submits for peer re-review.
Iterates until both agents agree on the final code state.

**Key**: You (the human) do NOT need to participate. Watch progress via `.review-loop/<session>/rounds.json` and `summary.md`.

**Compatibility note**: `rounds.json` keeps the historical field name `claude_actions` for backward compatibility. In Codex-hosted runs, that field still stores the host agent's decisions and code changes.

## Prerequisites

- **Required**: `git` CLI
- **Peer (one of)**: `codex` CLI (`codex --version`), `claude` CLI (`claude --version`), or `gemini` CLI (`gemini --version`)
- **Optional**: `gh` CLI (for PR scope detection)

## Configuration

### Defaults

| Setting | Default | Options |
|---------|---------|---------|
| `peer_reviewer` | `codex` | `codex`, `claude`, `gemini` |
| `max_rounds` | `5` | 1–10 |
| `timeout_per_round` | `600` | seconds |
| `scope_preference` | `auto` | `auto`, `diff`, `branch`, `pr` |
| `read_only` | `false` | `true` = report-only, no code changes |

The peer reviewer always runs with local repository access.

**Read-only mode** (`read_only: true`): Peer reviews code and the host agent evaluates findings, but NO code changes are made. Output is a findings report only — no fix commits, no code evolution loop. Useful when review-loop is used as a **sensor** by other skills (e.g., the bundled `harness` skill's Evaluator Tier 2). In read-only mode, Phase 2 (Code Evolution Loop) is skipped entirely — after Round 1 findings are evaluated, the loop goes directly to Phase 3 report generation with all findings classified as `reported` (not `accepted`/`rejected`).

### Override via project config

Create `.review-loop/config.json` in the project root to override defaults:

```json
{
  "peer_reviewer": "gemini",
  "max_rounds": 8
}
```

### Override via invocation

User can specify at invocation time: "review loop with gemini, max 3 rounds".
Invocation overrides take highest precedence.

---

## Phase 0 + 1: Preflight & Context Collection (Single Execution)

**IMPORTANT**: Run `preflight.sh` in a SINGLE bash call. This eliminates ~15 sequential tool calls.

```bash
SKILL_DIR="${SKILL_BASE_DIR:-}"
if [[ -z "$SKILL_DIR" || ! -x "$SKILL_DIR/scripts/preflight.sh" ]]; then
  for candidate in \
    "$(find ~/.claude/plugins/cache -path "*/review-loop" -type d 2>/dev/null | head -1)" \
    "$(find ~/.claude/skills -path "*/review-loop" -type d 2>/dev/null | head -1)" \
    "$(find ~/.codex/skills -path "*/review-loop" -type d 2>/dev/null | head -1)"; do
    [[ -x "$candidate/scripts/preflight.sh" ]] && SKILL_DIR="$candidate" && break
  done
fi

if [[ -z "$SKILL_DIR" ]]; then
  echo "Error: review-loop skill directory not found" >&2
  exit 1
fi

PREFLIGHT_OUTPUT="$($SKILL_DIR/scripts/preflight.sh \
  --peer {peer_reviewer} \
  --max-rounds {max_rounds} \
  --timeout {timeout_per_round} \
  --scope {scope_preference})"
# For a specific commit: add --commit-sha <SHA>
```

Pass user invocation-time overrides as CLI args — they take highest precedence.

**Precedence**: built-in defaults < `.review-loop/config.json` < CLI args

`preflight.sh` does ALL of the following in one shot:
1. Reads `.review-loop/config.json` (merges over defaults)
2. Applies CLI args (highest precedence — invocation overrides)
3. Checks peer CLI availability (falls back to alternative)
4. Detects base branch and repo root
5. Auto-detects review scope (local-diff → branch-commits → PR), or uses `--commit-sha` for a specific commit
6. Creates session directory with timestamp
7. Auto-adds `.review-loop/` to `.gitignore`
8. Initializes `rounds.json`
9. Collects the priority file list for the peer to inspect locally
10. Creates checkpoint commit
11. Collects project context (CLAUDE.md / package.json / README)

### Parse preflight output

The script outputs key-value pairs. Extract:
- `SESSION_DIR`, `SESSION_ID`, `PEER`, `SCOPE`, `BASE_BRANCH`, `REPO_ROOT`, etc.
- `TARGET_FILES_B64_START...TARGET_FILES_B64_END` — base64-encoded newline-separated file list
- `PROJECT_B64_START...PROJECT_B64_END` — base64-encoded project context

Decode with: `echo "$TARGET_FILES_B64" | base64 --decode`

If the script exits non-zero, stop and report the error.

### Log and proceed

Print to user:
```
Review Loop starting: {scope} ({detail}) → peer: {peer}, max: {max_rounds} rounds
```

### Build the initial review prompt

Use **Template 1** from [prompt-templates.md](references/prompt-templates.md) as a stable prompt contract.
Do NOT rewrite the prompt body each run. Only fill the small runtime fields:
- `repo_root`
- `scope_type` / `scope_detail`
- `target_files`
- a short `project_description`
- a compact `project_context` snippet when needed

Do NOT embed the full diff. Do NOT paste large sections of `CLAUDE.md` or README into the prompt. Round 1 should be a static template plus a lightweight runtime brief so prompt assembly stays cheap and consistent.
Write the completed prompt to:

```bash
PROMPT_FILE="$SESSION_DIR/peer-output/round-1-prompt.md"
```

### Step 1.3: Invoke peer reviewer

Determine the path to `peer-invoke.sh`. It is located relative to the skill's installed directory, NOT the project being reviewed:

```bash
# The skill's base directory is provided by Claude Code at invocation time.
# Look for it in the plugin cache or fall back to common install paths.
PEER_SCRIPT=""
for candidate in \
  "$SKILL_BASE_DIR/scripts/peer-invoke.sh" \
  "$(find ~/.claude/plugins/cache -path "*/review-loop/scripts/peer-invoke.sh" 2>/dev/null | head -1)" \
  "$(find ~/.claude/skills -path "*/review-loop/scripts/peer-invoke.sh" 2>/dev/null | head -1)" \
  "$(find ~/.codex/skills -path "*/review-loop/scripts/peer-invoke.sh" 2>/dev/null | head -1)"; do
  [[ -x "$candidate" ]] && PEER_SCRIPT="$candidate" && break
done

if [[ -z "$PEER_SCRIPT" ]]; then
  echo "Error: peer-invoke.sh not found. Ensure the review-loop skill is properly installed." >&2
  exit 1
fi
```

> **Note**: `$SKILL_BASE_DIR` is set by Claude Code from the skill's metadata. The fallback searches the plugin cache and skills directories.

`peer-invoke.sh` runs the selected peer in the current repository directory so it can read local files directly. For Codex, it also launches against an isolated temporary `CODEX_HOME` with no MCP servers, strips inherited `CODEX_API_KEY` by default, and records the peer session id for reuse in later rounds. For Claude, it uses JSON output mode and records the Claude session id for reuse.

Invoke:
```bash
$PEER_SCRIPT \
  --peer {peer_reviewer} \
  --prompt-file "$PROMPT_FILE" \
  --output-file "$SESSION_DIR/peer-output/round-1-raw.txt" \
  --session-id-file "$SESSION_DIR/peer-output/peer-session-id.txt" \
  --timeout {timeout_per_round}
```

### Step 1.4: Parse peer output

Read `round-1-raw.txt`. Parse for:
- `FINDING: fN` blocks → extract into structured findings
- `NO_FINDINGS:` → immediate consensus (skip to Phase 3)

### Step 1.5: Update rounds.json

Add Round 1 data with all `peer_findings`. Set `claude_actions` to empty (historical field name; stores host-side actions).

---

## Phase 2: Code Evolution Loop

**If `read_only: true`**: Skip this entire phase. Go directly to Phase 3 with all Round 1 findings classified as `reported` (not accepted/rejected). No code changes, no checkpoint commits, no re-review rounds.

For each round N (starting from Round 1's findings):

### Step 2.1: Evaluate findings

For each peer finding, apply the evaluation criteria from [synthesis-protocol.md](references/synthesis-protocol.md):

- **ACCEPT**: The finding is valid and actionable
- **REJECT**: The finding is a false positive or conflicts with project conventions — MUST attach a `Verification:` block per `protocol-quick-ref.md §verification-block`. Form B (verification-impossible) automatically downgrades to `deferred for verification`.

Record each decision with reasoning AND (for rejections) the `Verification:` block in `claude_actions[].verification`.

### Step 2.2: Implement accepted fixes

For each accepted finding:
1. Read the relevant file
2. Make the minimal code change to address the finding
3. Record the change in `claude_actions[].code_changes`

### Step 2.3: Checkpoint commit

```bash
git add -A && git commit -m "review-loop: changes from round {N}" --allow-empty
```

The `--allow-empty` flag ensures rounds where the host agent only rejects findings (no code changes) don't fail.

### Step 2.4: Update rounds.json

Update the current round's `claude_actions` with all decisions and changes.

### Step 2.5: Convergence check

Check if all findings are resolved:
- All findings ACCEPTED and fixed → peer needs to confirm fixes are correct
- Some findings REJECTED → peer needs to evaluate rejections
- If this is a re-review round and peer said `CONSENSUS:` → go to Phase 3

If round >= `max_rounds`:
- Mark remaining unresolved findings as `escalated`
- Go to Phase 3 with status `max_rounds`

### Step 2.6: Build re-review prompt

Use **Template 2** from [prompt-templates.md](references/prompt-templates.md):
- Keep the template body fixed
- Include only the files Claude changed this round via `git diff --name-only HEAD~1 HEAD`
- Include rejected findings with Claude's reasoning AND the verbatim `Verification:` block from `claude_actions[].verification` (so the peer can audit the evidence, not just the reasoning)
- Include a short summary of accepted/fixed findings

Do NOT paste the diff body into the prompt. Re-review should happen against the current local repository state.

Write to `$SESSION_DIR/peer-output/round-{N+1}-prompt.md`.

### Step 2.7: Invoke peer for re-review

```bash
if [[ -f "$SESSION_DIR/peer-output/peer-session-id.txt" ]]; then
  PEER_RESUME_ARGS=(--resume-session "$(cat "$SESSION_DIR/peer-output/peer-session-id.txt")")
else
  PEER_RESUME_ARGS=()
fi

$PEER_SCRIPT \
  --peer {peer_reviewer} \
  "${PEER_RESUME_ARGS[@]}" \
  --prompt-file "$SESSION_DIR/peer-output/round-{N+1}-prompt.md" \
  --output-file "$SESSION_DIR/peer-output/round-{N+1}-raw.txt" \
  --session-id-file "$SESSION_DIR/peer-output/peer-session-id.txt" \
  --timeout {timeout_per_round}
```

Reuse the same Codex session for re-review rounds when available. This avoids repeated cold starts, preserves the peer's review context, and materially reduces round-trip latency. Do NOT reuse that session for the final approval pass in Phase 3.

### Step 2.8: Parse re-review output

Look for:
- `CONSENSUS:` → all resolved, go to Phase 3
- `ACCEPTED_REJECTION: fN` → finding resolved, mark in rounds.json
- `INSIST: fN` → peer insists, the host agent must re-evaluate
- New `FINDING: fN` → new issues found in Claude's changes

### Step 2.9: Handle INSIST findings

For each `INSIST`:
1. Count how many rounds this finding has been debated
2. If debated < 2 rounds → Claude re-evaluates with peer's stronger argument
3. If debated >= 2 rounds → Mark as ESCALATED

Then loop back to Step 2.1 with the updated findings list.

---

## Phase 3: Final Consensus + Report

### Documentation / Protocol Scope Rule (load-bearing invariant)

When the review scope targets documentation or protocol files — defined as
any `.md` file under a skill's `references/`, `agents/`, or a repo-level
`dotfiles/` directory — fresh-final consensus (Step 3.2) is **load-bearing
and non-optional**. Historical evidence: on PR #42 the `codex-mode.md` ↔
`planning-protocol.md` escalation-rule contradiction (`rFinal.f1`) was
caught only by fresh-final; resumed-session rounds had converged on
CONSENSUS while the bug was still shipping.

Operational implications:

- Step 3.2 MUST run in a fresh peer session even if earlier rounds
  converged cleanly. Any future optimization that would skip fresh-final
  under "all rounds resolved quickly" heuristics MUST exclude this scope.
- If fresh-final reports new findings on docs/protocol scope with
  `read_only: false`, treat them as a new iteration round per Step 3.3 —
  Consensus is reached only when a fresh session returns zero findings.
- In `read_only: true` mode, fresh-final findings on docs/protocol scope
  MUST be surfaced in summary.md with the explicit note that these would
  have been blockers in normal mode — do not let them disappear silently
  into the generic `reported` bucket.

### Step 3.1: Build final consensus prompt

Use **Template 3** from [prompt-templates.md](references/prompt-templates.md).
Keep the template body fixed and fill only:
- `repo_root`
- `final_target_files`
- `resolution_table_rows`

This is the quality gate. Always run it in a fresh peer session, even if earlier re-review rounds reused the same Codex session.

Write to `$SESSION_DIR/peer-output/final-consensus-prompt.md`.

### Step 3.2: Invoke peer for final consensus in a fresh session

```bash
$PEER_SCRIPT \
  --peer {peer_reviewer} \
  --prompt-file "$SESSION_DIR/peer-output/final-consensus-prompt.md" \
  --output-file "$SESSION_DIR/peer-output/final-consensus-raw.txt" \
  --session-id-file "$SESSION_DIR/peer-output/final-peer-session-id.txt" \
  --timeout {timeout_per_round}
```

Important:
- Do NOT pass `--resume-session`
- This final pass must be independent from the iterative repair conversation

### Step 3.3: Parse final consensus output

Look for:
- `CONSENSUS:` → final approval confirmed, continue to report generation
- New `FINDING: fN` blocks → treat them as real blocking findings

If the fresh final pass reports new findings:
- **If `read_only: true`**: Record findings as `reported` in rounds.json. Do NOT return to Phase 2. Continue to report generation with status `read_only_complete`.
- If `read_only: false` and total rounds < `max_rounds`, append the findings as a new round and return to Phase 2.1
- If `read_only: false` and total rounds >= `max_rounds`, mark them as `escalated` and continue with status `max_rounds`

### Step 3.4: Complete rounds.json

Update session metadata:
- `completed_at`: current ISO timestamp
- `status`: `consensus`, `max_rounds`, or `read_only_complete`
- `total_rounds`: actual count
- `summary`: compute totals from all rounds

### Step 3.5: Generate summary.md

Write `$SESSION_DIR/summary.md` in this format:

```markdown
# Review Loop Summary

**Session**: {session_id}
**Peer**: {peer_reviewer} CLI
**Scope**: {scope} ({scope_detail})
**Rounds**: {total_rounds} | **Status**: {status_emoji} {status}

## Changes Made

{for each modified file: bullet with file path and description of change}

## Findings Resolution

| # | Finding | Severity | Action | Resolution |
|---|---------|----------|--------|------------|
{for each finding: row with id, title, severity, accept/reject, final status}

## Round Breakdown

| Source | Real issues found |
|--------|-------------------|
| Resumed-session rounds (r1–rN)   | {resumed_real_issue_count} |
| Fresh-final consensus pass       | {fresh_final_real_issue_count} |

Fresh-final contributed {fresh_final_real_issue_count}/{total_real_issue_count} real issues this session.

Count only findings that survived host evaluation (action=accept, or action=reject with Form B deferral). Exclude findings where the host's Form A verification produced empirical contradiction — those were peer false positives, not "real issues" for this purpose. The point of this breakdown is to track how much signal fresh-final finds that resumed rounds miss, so the load-bearing invariant in Phase 3 Documentation / Protocol Scope Rule stays visibly justified across sessions.

## Consensus

{if consensus: "Both Claude Code and {peer} agree the code is in good shape after {N} rounds."}
{if max_rounds: "Review stopped after {N} rounds. {M} items remain unresolved."}

{if summary.deferred_for_verification > 0:}
## Deferred for Verification

{for each finding with action == "deferred for verification": bullet with
  - finding id and title
  - peer's authority-only argument (the original finding description)
  - host's Form B `reason` (why verification was not possible)
  - note: "auto-downgraded per synthesis-protocol.md — peer is NOT required to re-evaluate; surfaced here for human follow-up."}

{if escalated items exist:}
## Escalated Items (Needs Human Decision)

{for each escalated finding: peer's argument, Claude's argument, recommendation}
```

The Deferred for Verification section is conditional: omit it entirely when `summary.deferred_for_verification == 0`. This section surfaces rejections that were auto-downgraded because they relied on authority (spec/design/conventions) without empirical proof per [protocol-quick-ref.md §verification-block](../harness/references/protocol-quick-ref.md#verification-block) Form B and [synthesis-protocol.md §Rejection Requirements](references/synthesis-protocol.md).

### Step 3.6: Terminal output

Print a concise summary to the user:

```
Review Loop complete.
  Session:    {session_id}
  Peer:       {peer_reviewer}
  Rounds:     {total_rounds}
  Status:     {status}
  Accepted:   {N} findings fixed
  Rejected:   {N} (resolved by peer)
  Escalated:  {N} (needs human decision)

  Details: .review-loop/{session_id}/summary.md
```

### Step 3.7: Update latest symlink

```bash
ln -sfn "{session_id}" .review-loop/latest
```

---

## Error Handling

| Error | Action |
|-------|--------|
| Peer CLI not found | Inform user, suggest installation command, offer alternative peer |
| Peer times out (exit 124) | Log timeout, mark round as failed, ask user whether to retry or stop |
| Peer output unparseable | Save raw output, inform user, attempt to extract any findings manually |
| Max rounds reached | Stop loop, generate report with `max_rounds` status, list unresolved items |
| Git operations fail | Stop loop, inform user, preserve current state |
| User cancels | Mark session as `aborted`, generate partial report |

---

## Examples

### Example 1: Basic local diff review

```
User: "review loop"
→ Detects local diff (5 files changed)
→ Logs startup config and proceeds
→ Round 1: Codex finds 3 issues
→ Claude accepts 2, rejects 1
→ Claude fixes accepted issues, commits
→ Round 2: Codex reviews fixes, accepts rejection reasoning
→ CONSENSUS after 2 rounds
```

### Example 2: PR review with Gemini

```
User: "review loop with gemini for PR 42"
→ Scope: PR #42
→ Peer: Gemini (override)
→ Round 1: Gemini finds 5 issues
→ Claude accepts 4, rejects 1
→ Round 2: Gemini insists on rejected finding
→ Claude re-evaluates, accepts
→ Round 3: Gemini confirms all fixes
→ CONSENSUS after 3 rounds
```

### Example 3: Max rounds reached

```
User: "review loop, max 3 rounds"
→ Round 1: Peer finds 8 issues
→ Round 2: 5 resolved, 3 debated
→ Round 3: 2 more resolved, 1 still debated
→ Status: max_rounds, 1 escalated finding
→ Summary shows escalated item for human decision
```
