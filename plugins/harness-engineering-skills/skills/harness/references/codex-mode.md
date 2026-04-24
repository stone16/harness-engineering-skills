# Harness — Codex-Hosted Execution

Use this reference when Codex is the orchestrator. The pipeline (Planning → Checkpoints → E2E → Review-Loop → Full-Verify → PR → Retro) is identical to the Claude Code-hosted path; only the sub-agent dispatch mechanism differs.

## Runtime Model

- Codex acts as the Orchestrator and local implementer (Generator role within checkpoints).
- `harness-engine.sh` remains the single source of truth for task state, checkpoints, and phase gates — same engine, same commands, same phase machine.
- Sub-agent roles (Spec Evaluator, Convention Scout, Evaluator, Retro) are dispatched via `claude-agent-invoke.sh` to a Claude CLI process. Any CLI that accepts a prompt and returns structured output can fill these roles.
- `review-loop` can use any available peer (`codex`, `claude`, or `gemini`) — the choice is a config option, not an architectural constraint.

> **Symmetry**: The role assignments are interchangeable. Just as Codex can host with Claude sub-agents, Claude Code can host with Codex as the review-loop peer. This document covers the Codex-as-host configuration.

## Prerequisites

- `codex --version`
- `claude --version` (when using Claude CLI for sub-agent roles)
- Reviewer agent definitions — `claude-agent-invoke.sh` resolves each agent in this order (first existing file wins):
  1. `~/.claude/agents/<name>.md` — user override (highest precedence).
  2. `<plugin-root>/agents/<name>.md` — plugin-bundled; the primary location, ships with this plugin at `plugins/harness-engineering-skills/agents/`.
  3. `<repo-root>/dotfiles/agents/<name>.md` — legacy fallback, preserved for backward compatibility with the private source repo.

## Script Discovery

Prefer the installed skill copy when present:

```bash
HARNESS_DIR="$(find ~/.codex/skills -path '*/harness' -type d 2>/dev/null | head -1)"
[[ -z "$HARNESS_DIR" ]] && HARNESS_DIR="$(find . -path '*/plugins/harness-engineering-skills/skills/harness' -type d 2>/dev/null | head -1)"

ENGINE="$HARNESS_DIR/scripts/harness-engine.sh"
CLAUDE_AGENT="$HARNESS_DIR/scripts/claude-agent-invoke.sh"
```

## Planning in Codex

1. Clarify requirements directly with the user.
   - If a dedicated brainstorming skill is unavailable in Codex, do the questioning and design synthesis manually.
2. At brainstorm start, fork the Scout agent with `--agent
   harness-convention-scout`; it writes
   `.harness/<task-id>/host-conventions-card.md` for Planner consumption.
3. At spec drafting start, strict-block for the Scout result using the same
   3-minute / 180-second timeout defined in [planning-protocol.md](planning-protocol.md).
   On timeout, crash, or `scout_status != complete`, proceed and record
   `Host Conventions Card: unavailable`.
4. Write `.harness/<task-id>/spec.md` in the normal Harness format. **After this step,
   the remainder of planning is autonomous** — see the "Post-Brainstorming Autonomy"
   section in [planning-protocol.md](planning-protocol.md).
5. For each spec-review round, invoke Claude as the spec reviewer (fresh each round):

```bash
"$CLAUDE_AGENT" \
  --agent harness-spec-evaluator \
  --prompt-file "$PROMPT_FILE" \
  --output-file ".harness/$TASK_ID/spec-review/round-${ROUND}-spec-review.md"
```

6. Apply accepted spec changes locally in Codex and write `round-N-planner-response.md`
   documenting accepted/rejected concerns with rationale. Repeat autonomously until
   `approve` verdict or `max_spec_rounds` is exhausted. Escalate to the user only
   in the scenarios enumerated in `planning-protocol.md`'s `Post-Brainstorming
   Autonomy` exhaustive list (max_spec_rounds exhaustion, critical-contradicts-design,
   or critical-acceptance-infeasible).
   - Rejecting a warning-severity concern requires a `Verification:` block in the
     Rejected Changes entry (see [protocol-quick-ref.md#verification-block](protocol-quick-ref.md#verification-block)).
     Critical concerns cannot be rejected — escalate per the
     `Post-Brainstorming Autonomy` rules in [planning-protocol.md](planning-protocol.md).

## Execution in Codex

For each checkpoint:

1. `"$ENGINE" begin-checkpoint ...`
2. `"$ENGINE" assemble-context ...`
3. Codex implements the checkpoint locally in the current session.
   - Do not require Codex subagents. Use them only if the user explicitly asked for delegation.
4. After each implementation iteration, invoke Claude for checkpoint evaluation:

```bash
"$CLAUDE_AGENT" \
  --agent harness-evaluator \
  --prompt-file "$PROMPT_FILE" \
  --output-file ".harness/$TASK_ID/checkpoints/$CHECKPOINT/iter-$ITER/evaluation.md" \
  --session-id-file ".harness/$TASK_ID/checkpoints/$CHECKPOINT/iter-$ITER/evaluator-session-id.txt"
```

5. Never create `evaluation.md` locally as the Codex Orchestrator. If Claude CLI is unavailable, stop in degraded-mode escalation before `pass-checkpoint`; do not mark the checkpoint passed from same-context self-evaluation.
6. Run `"$ENGINE" pass-checkpoint ...` only after `evaluation.md` has frontmatter `verdict: PASS` and `evaluator-session-id.txt` exists. The engine blocks missing artifacts, non-PASS verdicts, and evaluator session ids reused by prior checkpoints.
7. Treat `PASS`, `FAIL`, and `REVIEW` exactly as the normal Harness protocol defines.

## E2E, Full Verify, and Retro

- E2E evaluation: use `harness-evaluator` with the E2E prompt; write `e2e/iter-N/e2e-report.md` with frontmatter `verdict: PASS|FAIL|REVIEW`.
- Full verify: use `harness-evaluator` with the full-verify prompt and let Codex perform the fix loop locally.
- Retro: invoke `harness-retro` after PR creation.

## Cross-Model Review

After E2E passes, `review-loop` provides the cross-model quality gate. Configure it with any available peer:

- `peer_reviewer=claude` — Claude reviews Codex's implementation
- `peer_reviewer=codex` — a second Codex instance reviews (same-model, still useful for fresh context)
- `peer_reviewer=gemini` — Gemini reviews

Options:
- `read_only=false` — normal fix loop (peer finds issues, host fixes, iterate)
- `read_only=true` — report-only (collect signal without code changes)

`pass-review-loop` now treats `.review-loop/latest/rounds.json` as a completion contract: `session.status` must be `consensus` or `read_only_complete`, and `session.total_rounds` must be at least 1.

This is the same review-loop step that the Claude Code-hosted path runs. The peer choice is orthogonal to who hosts.
