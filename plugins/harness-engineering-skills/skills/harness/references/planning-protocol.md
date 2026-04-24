# Planning Protocol (Session 1)

**Recommended host**: Claude Code — interactive discovery, brainstorming skill, multi-turn Q&A.

You ARE the planner. Interact directly with the user.

## CRITICAL: Brainstorming Override

When `superpowers:brainstorming` is invoked within the Harness pipeline, the Harness workflow
**supersedes** brainstorming's terminal steps. Follow this partial-use protocol:

- **USE** brainstorming for requirements discovery ONLY (its steps 1–5: explore context →
  ask clarifying questions → propose 2–3 approaches → present design → get user approval)
- **STOP** after the user approves the design. Do NOT continue to brainstorming's steps 6–9
- **Do NOT** write to `docs/superpowers/specs/` — Harness uses `.harness/<task-id>/spec.md`
- **Do NOT** invoke `superpowers:writing-plans` — Harness replaces the plan phase with
  Spec Evaluator review (step 4 below). Detailed implementation steps are determined by
  Generator at execution time, not planned upfront.
- **Do NOT** follow brainstorming's process flow to its terminal state ("Invoke writing-plans skill")

After brainstorming produces an approved design, **return to step 3** below.

## Post-Brainstorming Autonomy (steps 3–7)

Once the user approves the brainstormed design in step 2, the remainder of the planning
pipeline is **fully autonomous**. Spec drafting, Spec Evaluator review, and the review
iteration run agent-to-agent until consensus.

### NEVER pause to ask the user between steps 3 and 7 about:
- Whether to proceed from brainstorm → spec draft (just draft it)
- Whether to spawn the Spec Evaluator (just spawn it)
- Whether to start the next spec-review round (just run it)
- Which Spec Evaluator concerns to accept/reject — apply judgment autonomously per
  severity (see step 5 below)
- "Ready for review?" / "Should I continue?" / mid-flow status confirmations

### The ONLY scenarios requiring human input after brainstorming (exhaustive list):
1. **`max_spec_rounds` exhausted without an `approve` verdict** — surface the final
   spec + unresolved concerns to the user.
2. Critical Spec Evaluator concern actually contradicts the brainstormed design — escalate to user; do not reject autonomously.
   (Warning-level concerns that contradict the brainstormed design are NOT an
   escalation trigger — they are handled autonomously per step 5's warning rule
   by attaching a `Verification:` block to the rejection.)
3. **Autonomous acceptance of a `critical` concern is infeasible** — step 5's
   critical rule says "ALWAYS accept" but if the revision cannot be performed
   within one round without breaking the brainstormed design, escalate rather
   than silently defer.

Everything else is autonomous. Record any remaining ambiguities in the spec's
`Open Questions` section rather than pausing to ask.

## Planning Flow

```
1. Receive task description from user

2. Clarify requirements:
   → Assign the task id early, then fork the Convention Scout in parallel with
     brainstorming so it can scan while the user conversation continues:
     - Claude Code: `Agent(subagent_type: "harness-convention-scout", prompt: <task id + repo root + output path .harness/<task-id>/host-conventions-card.md>)`
     - Codex-hosted planning: `claude-agent-invoke.sh --agent harness-convention-scout --prompt-file "$PROMPT_FILE" --output-file ".harness/<task-id>/host-conventions-card.md"`
   → Invoke superpowers:brainstorming for requirements discovery
   → Follow brainstorming's questioning process (explore, clarify, propose approaches,
     present design, get user approval)
   → STOP when user approves the design
   → Do NOT proceed to brainstorming's "Write design doc" / "Invoke writing-plans" steps

3. Produce spec.md → write to .harness/<task-id>/spec.md  (AUTONOMOUS — no user pause)
   → Strict-block on the Scout join before drafting the spec, with a 3-minute
     (180 seconds) timeout at the join point.
   → If the Card exists and has `scout_status: complete`, read it before
     writing Technical Approach and acceptance criteria.
   → If the Scout times out, crashes, writes no Card, or records
     `scout_status != complete`, proceed without pausing; the spec must record
     `Host Conventions Card: unavailable`, and Retro treats this as P0-P5
     absent for gap classification.
   → Convert the approved design into Harness spec format (see protocol-quick-ref.md)
   → Include checkpoints with ### Checkpoint NN: <title> format
   → Set status: draft in YAML frontmatter

4. Spawn Spec Evaluator sub-agent for spec review  (AUTONOMOUS — no user pause):
   → Agent(subagent_type: "harness-spec-evaluator", prompt: <spec + codebase context + protocol-quick-ref.md + prior deferred rejections>)
   → **Prior deferred rejections input** (rounds ≥ 2): include the prior
     `round-(N-1)-planner-response.md`'s Rejected Changes entries whose
     Verification: block is Form B (authority-only). Ask the Evaluator to
     decide, for each, whether to re-raise the concern in this round or accept
     the deferral. This is the executable path for the Form B deferral rule
     documented in `protocol-quick-ref.md §verification-block`.
   → Spec Evaluator writes round-N-spec-review.md (format in protocol-quick-ref.md)
   → Reviews: checkpoint quality, acceptance criteria testability, feasibility, failure modes

5. Iterate spec-review autonomously (max max_spec_rounds):
   → Fresh Spec Evaluator per round (not SendMessage) — each round reviews different spec version
   → Planner applies judgment AUTONOMOUSLY to each concern (no user pause):
     - critical severity → ALWAYS accept; cannot be rejected under the "contradicts brainstormed design" clause. Escalate to user if autonomous acceptance is infeasible.
     - warning severity → accept unless it contradicts the brainstormed design.
       Rejecting a warning concern requires a `Verification:` block in round-N-planner-response.md (format defined in protocol-quick-ref.md §verification-block).
     - info severity → accept if cheap; otherwise note in planner-response.md
   → Write round-N-planner-response.md documenting accepted/rejected changes
   → Loop continues until `approve` verdict or max_spec_rounds reached
   → Escalate to user in any of the three scenarios listed under "The ONLY
     scenarios requiring human input after brainstorming" above (max_spec_rounds
     exhaustion OR critical-contradicts-design OR autonomous acceptance of a
     critical concern is infeasible)

6. Mark spec status: approved

7. Hand off: "Spec approved. Switch to Codex and run 'harness continue'."
   (Or continue in same session — DEGRADED MODE: planning context pollutes
   execution. Requires explicit user confirmation.)
```
