---
name: harness
version: 0.14.0
description: |
  Cybernetics-based multi-agent orchestration for complex tasks. Coordinates a
  Planner → Generator → Evaluator → Retro pipeline with clean-context sub-agents,
  per-checkpoint drift prevention, and persistent retro learning.

  Recommended workflow: Claude Code plans the spec (Session 1), Codex executes
  autonomously (Session 2), Claude CLI reviews as cross-model peer.

  Use when: "harness this task", "use harness", "orchestrate this",
  "harness plan", "harness continue", "harness execute <task-id>",
  "harness <spec-name>", or when a task requires structured multi-agent coordination.
---

# Harness — Multi-Agent Orchestration

Orchestrate complex tasks through Planning → Generation ��� Evaluation → Retro.
Fresh sub-agents per checkpoint prevent drift. Retro accumulates learning across tasks.

## Recommended Workflow

```
Session 1 (Claude Code) → Brainstorm + Spec → Spec review with cross-model evaluator
    ↓ spec approved
Session 2 (Codex)       → Execute checkpoints → Evaluate → E2E → Full-verify → PR → Retro
    ↕ Claude CLI as review-loop peer (cross-model quality gate)
```

- **Session 1**: Claude Code for interactive discovery — brainstorming + multi-turn Q&A to establish requirements. **After the user approves the brainstormed design, spec drafting and the Spec Evaluator review loop run autonomously** (agent-to-agent until consensus). See [references/planning-protocol.md](references/planning-protocol.md) "Post-Brainstorming Autonomy".
- **Session 2**: Codex for autonomous execution — implementation, evaluation, PR creation, retro. Claude CLI serves as cross-model reviewer via `review-loop`.
- Both hosts support both phases. The above is the **recommended** flow, not a hard constraint.

## Prerequisites

1. `superpowers` plugin installed (Claude Code): Generator preloads TDD, verification, debugging skills
2. Reviewer role definitions: `harness-spec-evaluator.md`, `harness-generator.md`, `harness-evaluator.md`, `harness-retro.md` — ship with this plugin at `plugins/harness-engineering-skills/agents/`; user overrides may live at `~/.claude/agents/harness-*.md`
3. `python3` on PATH (engine JSON operations)
4. `git` repository initialized
5. For Codex-hosted execution: `claude` CLI on PATH for sub-agent dispatch and review-loop

Verify (Claude Code): `claude plugin list | grep superpowers`
Verify (review roles): `ls ~/.claude/plugins/**/plugins/harness-engineering-skills/agents/harness-*.md 2>/dev/null || ls plugins/harness-engineering-skills/agents/harness-*.md` (plugin-bundled) and `ls ~/.claude/agents/harness-*.md 2>/dev/null` (optional user override)
Verify (Codex): `codex --version && claude --version`

## Engine Script

All deterministic state management is handled by `harness-engine.sh`. To locate it:

```bash
ENGINE="$(find ~/.claude/plugins/cache -path "*/harness/scripts/harness-engine.sh" -type f 2>/dev/null | head -1)"
```

If not found, try `find ~/.claude/skills -path "*/harness/scripts/harness-engine.sh"` or `find ~/.codex/skills -path "*/harness/scripts/harness-engine.sh"` as fallback. In a checked-out repo, `plugins/harness-engineering-skills/skills/harness/scripts/harness-engine.sh` is also valid.

Delegate ALL file-system and git bookkeeping to the engine.

## Configuration

| Setting | Default | Options |
|---------|---------|---------|
| `max_spec_rounds` | `3` | 1–5 |
| `max_eval_rounds` | `3` | 1–5 |
| `cross_model_review` | `true` | `true` → triggers `review-loop` after E2E, before PR |
| `cross_model_peer` | `codex` | `codex`, `claude`, `gemini` — use `claude` when Codex is the host |
| `cross_model_read_only` | `false` | `true` = report-only, `false` = iterative fix |
| `auto_retro` | `true` | `false` to skip retro |
| `claude_md_path` | `auto` | Path to CLAUDE.md. `auto` detects |
| `max_verify_rounds` | `3` | 1–5, max iterations for full-verify fix loop |
| `coverage_threshold` | `85` | Hard minimum — FAIL if below this % |
| `skip_full_verify` | `false` | `true` → skip full-verify phase |

**Precedence**: defaults < `.harness/config.json` < invocation args

Read config: `$ENGINE read-config [--max-spec-rounds N] [--max-eval-rounds N] ...`

## Architecture

```
Orchestrator (you, the Main Agent — Claude Code or Codex)
├── Planning Phase     → YOU are the Planner (direct user interaction)
│   ↕ spec-review/     → iterate with Spec Evaluator on checkpoint quality
├── Spec Evaluator     → sub-agent, architecture + feasibility
├── Generator          → sub-agent (or local in Codex), TDD skill preloaded
│   ↕ evaluation       → iterate with Evaluator per checkpoint
├── Evaluator          → sub-agent, composite sensor
└── Retro              → sub-agent, produces retro.md
```

**Sub-agent dispatch:** In Claude Code use `Agent(subagent_type: "harness-*", prompt: <context>)`. In Codex use `claude-agent-invoke.sh` to dispatch via CLI. See [references/codex-mode.md](references/codex-mode.md) for Codex-specific details.

**Anti-drift mechanisms:**
- Fresh Generator + Evaluator per checkpoint (full eigenbehavior reset)
- SendMessage reuse within checkpoint iterations (bounded trade-off for efficiency)
- Two-session split: planning context discarded before execution
- Engine hard gates: `pass-checkpoint` requires latest `evaluation.md` verdict PASS plus fresh evaluator session proof (`evaluator-session-id.txt` not reused by prior checkpoints), `pass-e2e` requires latest `e2e-report.md` verdict PASS, and `pass-review-loop` requires a completed review-loop session.

## File System Layout

```
.harness/
├── config.json                         # Project config (git-tracked)
├── <task-id>/                          # Per-task (gitignored)
��   ├── spec.md
│   ├── git-state.json
│   ├── spec-review/
│   │   ├��─ round-N-spec-review.md
│   │   ├── round-N-planner-response.md
│   │   └─��� status.md
│   ├── checkpoints/
│   │   └── NN/
│   │       ├── context.md
│   │       ├── iter-N/
���   │       │   ├── output-summary.md
│   │       │   ├── evaluation.md
│   │       │   ├── evaluator-session-id.txt
│   │       │   └── evidence/
│   │       └── status.md
│   ├── e2e/
│   │   ├── iter-N/ {context.md, e2e-report.md, evidence/}
│   ���   └── status.md
│   ├── full-verify/
│   │   ├── discovery.md
│   ��   ├── iter-N/
│   │   │   ├── verification-report.md
│   │   │   └── evidence/
│   │   └── status.md
│   └── retro-input.md
└── retro/                              # Persistent (git-tracked)
    ├���─ index.md
    └── <date>-<task-id>.md
```

Gitignore entries are auto-added by `$ENGINE init`.

## Protocol Loading

This skill splits into two protocol files to minimize context usage. **Read the one matching your intent before proceeding.**

| Intent | Trigger phrases | Action |
|--------|----------------|--------|
| **Planning** | "harness plan", "harness this task", "use harness", "harness spec" | Read [references/planning-protocol.md](references/planning-protocol.md) |
| **Execution** | "harness continue", "harness execute <task-id>", "harness <spec-name>" | Read [references/execution-protocol.md](references/execution-protocol.md) |

**After loading the protocol, follow it completely.** Do not proceed without reading the appropriate reference file.

## Reference Files

- [references/planning-protocol.md](references/planning-protocol.md) — Session 1: spec creation and review (Claude Code recommended)
- [references/execution-protocol.md](references/execution-protocol.md) — Session 2: checkpoint execution through retro (Codex recommended)
- [references/protocol-quick-ref.md](references/protocol-quick-ref.md) — All file format specs (passed to agents via prompt)
- [references/checkpoint-definition.md](references/checkpoint-definition.md) — Checkpoint definition, numbering, granularity, scope constraint, and Planner guidance
- [references/codex-mode.md](references/codex-mode.md) — Codex-hosted sub-agent dispatch details
