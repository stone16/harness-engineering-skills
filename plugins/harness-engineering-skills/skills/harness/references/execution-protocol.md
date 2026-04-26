# Execution Protocol (Session 2)

**Recommended host**: Codex — autonomous execution, Claude CLI as cross-model reviewer.

**Sub-agent dispatch**: In Claude Code use `Agent(subagent_type: "harness-*", ...)`. In Codex, the host implements locally (Generator role) and dispatches review-heavy roles via `claude-agent-invoke.sh`. See [codex-mode.md](codex-mode.md) for Codex-specific details.

## Autonomous Execution Principle

**The Harness pipeline is FULLY AUTONOMOUS during execution.** Once the user says "harness continue" or "harness execute", run the entire pipeline to completion without pausing.

### NEVER pause to ask the user about:
- Whether to proceed to the next checkpoint (just proceed)
- Whether to invoke `review-loop` (just invoke it)
- Whether to create a PR (just create it)
- Whether to run retro (just run it)
- Whether to spawn a Generator or Evaluator (just spawn them)
- Whether to run full-verify (just run it)
- Checkpoint transition confirmations of any kind
- "Should I continue?" or "Ready for the next step?" questions

### The ONLY scenarios requiring human input (exhaustive list):
1. **REVIEW verdict with `auto_resolvable=false`** — spec ambiguity, architectural trade-off, or security concern
2. **FAIL verdict after `max_eval_rounds` exhausted** — Generator cannot fix the issue
3. **E2E failure after max retries** — cross-checkpoint integration broken
4. **Task discovery with multiple matches** — user must choose which task
5. **Degraded mode confirmation** — continuing in same session as planning
6. **Full-verify failure after `max_verify_rounds` exhausted** — all checks still failing

**Everything else is autonomous.** Phase transitions, skill invocations, sub-agent spawning, review-loop execution — all happen automatically. The engine's phase gates enforce correctness.

## Testing Strategy (By Checkpoint Type)

Testing requirements differ by checkpoint type — backend values test coverage, frontend values interaction proof.

### Backend / Infrastructure (`Type: backend` | `Type: infrastructure`)

**TDD Red-Green-Refactor is MANDATORY:**

1. **Red** — Write failing tests that encode acceptance criteria BEFORE implementation
2. **Green** — Minimum code to make all tests pass
3. **Refactor** — Clean up while keeping tests green

| Requirement | Threshold | Enforcement |
|------------|-----------|-------------|
| Test coverage | `coverage_threshold` from `.harness/config.json` (default 85%) or stricter spec value | FAIL if below or unmeasured — checkpoint Evaluator and full-verify Evaluator both enforce |
| Integration / E2E tests | ≥ 1 per checkpoint | Spec Evaluator checks testability |
| TDD evidence | Red commit → Green commit | Evaluator verifies commit sequence |

### Frontend (`Type: frontend`)

**E2E interaction + visual verification is MANDATORY. Unit test coverage is NOT required.**

| Requirement | Threshold | Enforcement |
|------------|-----------|-------------|
| E2E / browser test | ≥ 1 per checkpoint | Golden path exercise |
| Screenshots | MANDATORY | Key states in `evidence/` |
| Console errors | Zero | Browser verification |
| Unit test coverage | NOT required unless the spec explicitly requires it | No coverage threshold unless specified |

### Fullstack (`Type: fullstack`)

Apply **backend rules to the backend portion** and **frontend rules to the frontend portion**. Both evidence types required.

### PR Testing Evidence (Mandatory)

Every PR MUST include `## Testing Verification`:
- **Backend PRs**: Test output summary (pass count, coverage %), sample request/response
- **Frontend PRs**: Screenshots, E2E evidence, zero console errors
- **Fullstack PRs**: Both of the above

## Task Discovery (for "harness continue")

Use the engine: `$ENGINE discover`

Output: `MATCH_COUNT`, `BRANCH`, and `MATCH=<task-id>|<title>|<spec-path>` lines.
One match → load. Multiple → ask user. None → inform user.

## Execution Flow

**Execute the entire flow below autonomously — do NOT pause between steps or ask for confirmation.**

```
1. Load spec.md, confirm status=approved
2. Initialize: $ENGINE init --task-id <task-id>

3. For each checkpoint (sequential, proceed automatically):
   a. $ENGINE begin-checkpoint --task-id <id> --checkpoint <NN>
   b. $ENGINE assemble-context --task-id <id> --checkpoint <NN>
      → Outputs CHECKPOINT_TYPE for downstream skill injection
   c. Read the generated context.md
   d. Spawn fresh Generator:
      → Agent(subagent_type: "harness-generator", prompt: <context.md + protocol-quick-ref.md>)
      → Based on CHECKPOINT_TYPE and checkpoint scope, consider which available skills
        are relevant and let the Generator know. The Generator decides whether to invoke them.
   e. Generator → code + atomic commits + output-summary.md
   f. $ENGINE end-iteration --task-id <id> --checkpoint <NN>
   g. Spawn fresh Evaluator:
      → Agent(subagent_type: "harness-evaluator", prompt: <checkpoint spec + diff + output-summary + protocol-quick-ref.md>)
      → Evaluator receives ONLY: this checkpoint's spec + git diff + output-summary
        (NOT full spec, NOT prior checkpoints)
      → Diff source: git diff baseline_sha..HEAD (iter 1) or previous end_sha..HEAD (iter 2+)
      → In Codex-hosted execution, this means invoking `claude-agent-invoke.sh`; do not hand-write
        `evaluation.md` locally as the Orchestrator.
   h. Evaluator → evaluation.md + evidence/
      → `evaluation.md` MUST include frontmatter `verdict: PASS|FAIL|REVIEW`
      → In Codex-hosted execution, `claude-agent-invoke.sh` MUST write
        `evaluator-session-id.txt`; this is the proof that a separate Evaluator agent ran.
      → The evaluator MUST read `.harness/config.json` and the checkpoint spec, and apply the
        stricter of the configured coverage threshold and any spec-specific threshold.
   i. VERDICT:
      - PASS → $ENGINE pass-checkpoint --task-id <id> --checkpoint <NN>
               (engine blocks unless latest output-summary.md exists,
                latest evaluation.md verdict is PASS, and evaluator session proof exists
                and was not used by a prior checkpoint)
               → Immediately proceed to next checkpoint (no pause, no user confirmation)
      - FAIL → SendMessage same Generator with feedback (include evaluation.md)
               → Generator fixes code + commits
               → $ENGINE end-iteration --task-id <id> --checkpoint <NN>
               → SendMessage same Evaluator to re-evaluate
               → max max_eval_rounds, then escalate to human
      - REVIEW (auto_resolvable=true) → treat like FAIL:
               → Send review_items + fix_hints to Generator as feedback
               → Generator fixes mechanically + commits
               → $ENGINE end-iteration --task-id <id> --checkpoint <NN>
               → SendMessage same Evaluator to re-evaluate
               → If re-evaluation is PASS → continue
               → If still REVIEW/FAIL after max_eval_rounds → escalate to human
               → NEVER ask user to choose fix strategy for auto-resolvable items
      - REVIEW (auto_resolvable=false) → escalate to human:
               → Pause, show evaluation.md + evidence to user
               → User decides: provide guidance, fix manually, or abort

4. E2E verification (proceed automatically after last checkpoint passes):
   → $ENGINE begin-e2e --task-id <id>
   → Fresh Evaluator in E2E mode (cross-checkpoint integration + data-flow audit)
   → Evaluator writes e2e/iter-N/e2e-report.md with frontmatter `verdict: PASS|FAIL|REVIEW`
   → Two responsibilities:
     a. Verify spec's Success Criteria end-to-end (existing)
     b. Data-flow audit: independently read all checkpoint code, identify values
        that flow across checkpoint boundaries (via props, cache, API, store),
        trace each producer→consumer path for shape match and staleness risk.
        Use "Depends on" fields from spec to prioritize which flows to trace.
        Report as: | Flow | Producer (CP) → Consumer (CP) | Boundary | Match? | Staleness? |
   → If FAIL → spawn Generator to fix seam, max 2 retries, then escalate
   → On success: $ENGINE pass-e2e --task-id <id>
     (engine blocks unless latest e2e-report.md verdict is PASS)

5. Cross-model review (ENFORCED by engine phase gate — execute automatically, do NOT ask user):
   → If cross_model_review=true (default):
     → Directly invoke `review-loop` with scope: branch (no confirmation needed)
     → When Codex is the host, set cross_model_peer=claude for true cross-model review
     → Default mode: read_only=false (peer finds issues, host fixes, iterate to consensus)
     → review-loop produces .review-loop/<session>/summary.md + rounds.json
     → If review-loop finds critical issues → fix and re-run E2E (step 4)
     → $ENGINE pass-review-loop --task-id <id>
       (engine verifies .review-loop/latest/summary.md + rounds.json exist,
        session.status is consensus/read_only_complete, and session.total_rounds >= 1)
   → If cross_model_review=false:
     → $ENGINE skip-review-loop --task-id <id>
       (engine verifies config flag before allowing skip)

6. Full-verify (proceed automatically after review-loop — do NOT ask user):
   → If skip_full_verify=true in config:
     → $ENGINE skip-full-verify --task-id <id>
     → Skip to step 7 (PR creation)
   → $ENGINE begin-full-verify --task-id <id>
   → Discovery: Orchestrator parses package.json scripts using
     python3 -c "import json; d=json.load(open('package.json')); print('\n'.join(k for k in d.get('scripts',{}) if k in ('test','typecheck','type-check','lint','build')))"
     If no package.json, check Makefile for targets: grep -E '^(test|lint|check):' Makefile
     Write full-verify/discovery.md per protocol format
   → If no commands discovered:
     - If spec contains ANY checkpoint with `Type: backend`, `infrastructure`, or `fullstack`:
       → FAIL — backend work requires discoverable test/coverage commands
       → Escalate to human: "No test commands found but backend checkpoints exist"
     - If ALL checkpoints are `Type: frontend`:
       → Write full-verify/iter-1/verification-report.md with verdict PASS_WITH_WARNINGS
         + soft warning "no check commands found — frontend-only, E2E evidence required in PR"
       → $ENGINE pass-full-verify --task-id <id>
   → Spawn fresh Evaluator in full-verify mode:
     → prompt includes: discovered commands, full spec's Success Criteria,
       coverage_threshold from config, instruction to write
       full-verify/iter-N/verification-report.md per protocol format
   → Evaluator runs all discovered commands, collects coverage data,
     writes verification-report.md + evidence/
   → If FAIL: spawn fresh Generator with verification-report.md as feedback
     → Generator fixes code + commits
     → Re-run Evaluator, max max_verify_rounds iterations
     → If still FAIL after max_verify_rounds → escalate to human
   → If PASS (soft warnings allowed): $ENGINE pass-full-verify --task-id <id>

7. PR creation (proceed automatically — do NOT ask user before creating PR):
   → Collect testing evidence from checkpoint evaluations + full-verify report
   → Build PR body with mandatory `## Testing Verification` section:
     - Test pass count + coverage % from full-verify
     - For UI checkpoints: embed screenshots from evidence/ directories
     - For API checkpoints: include sample request/response output
   → Use `superpowers:finishing-a-development-branch` or `ship` if available
   → $ENGINE pass-pr --task-id <id> --pr-url <url>
     (engine requires the PR URL as proof — phase blocks retro until PR is recorded)

8. Retro (proceed automatically — do NOT ask user before running retro):
   → $ENGINE assemble-retro-input --task-id <id>
     (BLOCKED by engine unless phase == "pr")
   → Include review-loop summary.md + rounds.json in retro input if available
9. Spawn Retro sub-agent:
   → Agent(subagent_type: "harness-retro", prompt: <retro-input.md + review-loop summary + historical retros + protocol-quick-ref.md>)
10. Retro → .harness/retro/<date>-<task-id>.md + update index.md
    → Drafts exact CLAUDE.md rule text for user to approve/edit/reject
    → Analyzes: which issues did the peer catch that the host missed? (cross-model learning)

11. Auto-create GitHub issues from retro findings (proceed automatically):
    → Parse Issue-ready items; read required `target_repo` (`protocol-quick-ref.md §issue-routing`)
    → Missing/invalid `target_repo`: list titles, surface to user, skip those items; never default to `host`
    → Route `host` with plain `gh issue create`; route `harness` with `gh issue create --repo https://github.com/stone16/harness-engineering-skills`
    → Route `both`: create both, edit both bodies with `Cross-filed: <other_url>`, record `- Proposal N (both): <harness-url> | <host-url>`
    → On any of the four `both` create/edit calls failing, record partial state in "## Filed Issues" and continue; skip all filing if `gh` is unavailable

12. $ENGINE complete --task-id <id>
    → Report to user (this is the ONLY time you summarize results to the user)
```

Step 11 concrete routing snippet:

```bash
set -uo pipefail
HOST_URL=$(gh issue create --title "$TITLE" --body-file "$BODY_FILE" --label "harness-retro")
HARNESS_URL=$(gh issue create --repo https://github.com/stone16/harness-engineering-skills --title "$TITLE" --body-file "$BODY_FILE" --label "harness-retro")
gh issue edit "$HARNESS_URL" --body-file <(printf '%s\nCross-filed: %s\n' "$(cat "$BODY_FILE")" "$HOST_URL")
gh issue edit "$HOST_URL" --body-file <(printf '%s\nCross-filed: %s\n' "$(cat "$BODY_FILE")" "$HARNESS_URL")
```

## Phase State Machine

The engine enforces a linear phase progression in `git-state.json`:

```
init → checkpoints → e2e → review-loop → full-verify → pr → retro → done
```

Each downstream command checks the current phase before executing. If the phase is wrong, the engine returns `PHASE_BLOCKED` with the required next step.

| Phase Transition | Engine Command | Verification |
|-----------------|----------------|--------------|
| init → checkpoints | `begin-checkpoint` (first) | Automatic |
| checkpoints → e2e | `pass-e2e` | E2E evaluator passes |
| e2e → review-loop | `pass-review-loop` or `skip-review-loop` | Artifact files exist / config allows skip |
| review-loop → full-verify | `begin-full-verify` (then `pass-full-verify` or `skip-full-verify`) | Fresh verification report with PASS verdict / config allows skip |
| full-verify → pr | `pass-pr --pr-url <url>` | PR URL provided |
| pr → retro | `assemble-retro-input` | Automatic |
| retro → done | `complete` | Retro has run |

### State Validation

Before each operation, validate the transition is legal:
```
$ENGINE validate-transition --task-id <id> <target-command>
```

If `TRANSITION_DENIED`, fix the issue autonomously. Only inform the user if the fix requires human input per the exhaustive list above.

### Git State Tracking

The engine maintains `.harness/<task-id>/git-state.json`:
```json
{
  "task_id": "...",
  "task_start_sha": "...",
  "checkpoints": {
    "01": {
      "baseline_sha": "...",
      "iterations": { "1": { "end_sha": "..." } },
      "final_sha": "...",
      "aborted": false
    }
  },
  "e2e_baseline_sha": "...",
  "e2e_final_sha": "..."
}
```

Read state: `$ENGINE status --task-id <id>`

## Abort & Rollback

On "harness abort" or "stop":
```
$ENGINE abort --task-id <id> [--checkpoint <NN>]
```

1. Auto-detects active checkpoint (or uses `--checkpoint`)
2. `git reset --hard` to checkpoint's `baseline_sha`
3. Marks checkpoint as ABORTED in git-state.json
4. Writes status.md = ABORTED
5. PASSED checkpoint commits preserved
6. Run partial retro if `auto_retro=true`
7. Resume: `harness continue` skips PASSED and ABORTED checkpoints

## Error Handling

| Error | Action |
|-------|--------|
| Generator empty commit | FAIL, send specific feedback (autonomous retry) |
| Evaluator timeout | Retry once, then REVIEW for human |
| Git failure | Attempt auto-recovery; only pause for user if unrecoverable |
| Sub-agent crash | Spawn fresh agent, retry iteration (autonomous) |
| Max iterations | Escalate to human with context (this IS in the exhaustive pause list) |
| E2E fails after retries | Escalate with integration analysis (this IS in the exhaustive pause list) |
| Full-verify fails after retries | Escalate to human with verification-report.md (this IS in the exhaustive pause list) |
| User abort | Run abort flow above |

**Escalation note:** Escalation to human is rare — it only occurs for the scenarios listed in the Autonomous Execution Principle section above.

## Generator Rule Conflict Handling

When Generator encounters conflicting rules:
1. Choose the rule aligned with spec's success criteria
2. Document conflict in output-summary.md "Rule Conflict Notes"
3. Retro detects these post-hoc for future resolution

## Dependencies

**Required:**

| Dependency | Used By | Purpose |
|-----------|---------|---------|
| `superpowers` plugin | Generator, Orchestrator | TDD (preloaded), verification-before-completion, systematic-debugging, brainstorming in Claude Code |
| `sto` plugin (this skill) | Orchestrator | `review-loop` in Claude Code |
| `claude` CLI | Codex-hosted Orchestrator | Sub-agent roles + optional `review-loop --peer claude` |

**Optional (enhanced capabilities):**

| Dependency | Fallback |
|-----------|----------|
| `agent-browser` / `gstack` | Evaluator skips browser checks |
| `qa-only` (gstack) | Evaluator uses manual test runs for frontend Tier 1 |
| `ship` (gstack) | Orchestrator creates PR manually via `gh pr create` |

## Agent Files

Agent definitions are resolved by `scripts/claude-agent-invoke.sh` via a 3-tier lookup (first existing file wins):

1. `~/.claude/agents/<name>.md` — user override (highest precedence).
2. `<plugin-root>/agents/<name>.md` — plugin-bundled; the primary location for plugin-distributed agents (e.g. `plugins/harness-engineering-skills/agents/`).
3. `<repo-root>/dotfiles/agents/<name>.md` — legacy path, preserved for backward compatibility with the private source repo that shipped agents under `dotfiles/agents/`.

| Agent | File | Preloaded Skills | Role |
|-------|------|-----------------|------|
| Spec Evaluator | `harness-spec-evaluator.md` | — | Spec quality, checkpoint review, feasibility |
| Generator | `harness-generator.md` | `superpowers:test-driven-development`, `superpowers:verification-before-completion`, `superpowers:systematic-debugging` | Code implementation + FAIL retry |
| Evaluator | `harness-evaluator.md` | — | Independent evaluation |
| Retro | `harness-retro.md` | — | Retrospective analysis |
