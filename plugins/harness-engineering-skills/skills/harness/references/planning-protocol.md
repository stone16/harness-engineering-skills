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

## Planning Flow

```
1. Receive task description from user

2. Clarify requirements:
   → Invoke superpowers:brainstorming for requirements discovery
   → Follow brainstorming's questioning process (explore, clarify, propose approaches,
     present design, get user approval)
   → STOP when user approves the design
   → Do NOT proceed to brainstorming's "Write design doc" / "Invoke writing-plans" steps

3. Produce spec.md → write to .harness/<task-id>/spec.md
   → Convert the approved design into Harness spec format (see protocol-quick-ref.md)
   → Include checkpoints with ### Checkpoint NN: <title> format
   → Set status: draft in YAML frontmatter

4. Spawn Spec Evaluator sub-agent for spec review:
   → Agent(subagent_type: "harness-spec-evaluator", prompt: <spec + codebase context + protocol-quick-ref.md>)
   → Spec Evaluator writes round-N-spec-review.md (format in protocol-quick-ref.md)
   → Reviews: checkpoint quality, acceptance criteria testability, feasibility, failure modes

5. Iterate spec-review (max max_spec_rounds, then escalate to user)
   → Fresh Spec Evaluator per round (not SendMessage) — each round reviews different spec version
   → Planner writes round-N-planner-response.md documenting accepted/rejected changes

6. Mark spec status: approved

7. Hand off: "Spec approved. Switch to Codex and run 'harness continue'."
   (Or continue in same session — DEGRADED MODE: planning context pollutes
   execution. Requires explicit user confirmation.)
```
