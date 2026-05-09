# Record Generator and Planner Host + Model in Harness Artifacts

## Status

Proposed

## Date

2026-05-09

## Deciders

- Harness maintainers

## Context

Harness already records `evaluator_host` and `evaluator_session_id` in
`evaluation.md` frontmatter, which lets a downstream consumer attribute each
evaluation to a specific AI host (Claude Code, Codex, Gemini CLI, etc.).

The same attribution does **not** exist for the Generator (the agent that
writes code per checkpoint) or the Planner (the agent that drafts `spec.md`).
A retrospective analysis attempting to answer questions like "did Codex 5.5 +
Claude 4.7 raise our one-shot pass rate?" or "which model writes specs that
need fewer review rounds?" must currently infer host from indirect signals
(branch name prefixes, ccusage daily token counts, evaluator_host plus
cross-model assumptions). Each of those proxies has known failure modes.

The gap also makes it impossible to do same-host model-version comparisons
even on the evaluator side — `evaluator_host: claude-cli` covers Claude Opus
4.6 and Opus 4.7 alike, so a 6-week dataset that spans the 4.6 → 4.7 cutover
cannot be cleanly partitioned without resorting to date-based heuristics.

Because each artifact is written by an agent that *knows* which model it is
running, recording this information at write time is cheap. The value
compounds across tasks: with the fields in place, future analyses can
attribute every iter, every spec, and every evaluation to a concrete
(host, model) pair.

## Decision Drivers

- Attribution should not depend on inference from token-usage logs whose
  format is owned by a third-party tool.
- Existing `evaluator_host` is the precedent — Generator, Planner, and
  Evaluator should be symmetric in what they record.
- New fields must be **optional** so that older `.harness/` artifacts and
  existing parsers continue to work unchanged.
- Field names must be self-explanatory and avoid abbreviations so consumers
  can grep across artifacts without ambiguity.
- The cost of recording is one frontmatter line per agent; the cost of *not*
  recording is permanent loss of attribution data once a task completes.

## Options Considered

- **Status quo** — keep inferring host and model from `evaluator_host` plus
  ccusage daily logs.
- **Record only host** — add `generator_host` and `planner_host` fields but
  skip the model version, leaving "which Opus" or "which gpt-5.x" still
  ambiguous.
- **Record host + model + session id** — add a small frontmatter block per
  agent, mirroring the existing evaluator pattern.
- **Record host + model + session id + start/end timestamps** — also capture
  per-iteration wall-clock duration, supporting cost and latency analysis
  later.

## Decision

Adopt the **host + model + session id + timestamps** option. Specifically:

1. **`output-summary.md`** (per iteration, written by Generator) gains five
   optional frontmatter fields:
   - `generator_host` (e.g., `codex-cli`, `claude-code-agent`)
   - `generator_model` (e.g., `gpt-5.5`, `claude-opus-4-7`)
   - `generator_session_id`
   - `generator_started_at` (ISO-8601)
   - `generator_completed_at` (ISO-8601)
2. **`spec.md`** (per task, written by Planner) gains three optional
   frontmatter fields:
   - `planner_host`
   - `planner_model`
   - `planner_session_id`
3. **`evaluation.md`** (already has `evaluator_host` and
   `evaluator_session_id`) gains one new optional field for symmetry:
   - `evaluator_model`

All seven new fields are optional — engine commands and existing parsers
continue to ignore them. Agents that know their host and model SHOULD
populate them; agents that cannot determine the value MAY omit the field.

## Consequences

- **Positive**:
  - Per-iter attribution becomes possible without inference. Analyses like
    "Generator pass rate by model" become arithmetic instead of guesswork.
  - Same-host model-version splits (4.6 vs 4.7, 5.4 vs 5.5) become trivial.
  - Symmetry across Generator / Planner / Evaluator simplifies parsers —
    one mental model for all three artifact types.
  - Optional adoption means no migration required for existing
    `.harness/<task-id>/` directories.
- **Negative**:
  - Each agent must know its own host and model. For Claude Code sub-agents,
    this is exposed via the runtime context. For Codex, the orchestrator
    injects it via prompt. For other hosts, populating these fields requires
    upstream changes outside this repo.
  - Field names are not validated by the engine, so a typo (e.g.,
    `generator_modle`) would silently fail to attribute. Documentation in
    `protocol-quick-ref.md` is the only safeguard at v1.
- **Neutral**:
  - Old artifacts remain readable. Consumers must handle the optional case
    (field present, absent, or empty string).
  - The exact string convention for `*_model` (e.g., `claude-opus-4-7` vs
    `claude-opus-4-7-20260416`) is left to the writer; documentation
    recommends the short canonical form to keep grep-friendly.

## Validation

- Run a fresh Harness task end-to-end after the agent prompt updates and
  confirm `spec.md`, every `output-summary.md`, and every `evaluation.md`
  contain the new frontmatter fields.
- Existing tasks under `.harness/<task-id>/` must continue to satisfy the
  engine's `pass-checkpoint`, `pass-e2e`, `pass-full-verify` gates without
  modification (backwards-compat check).
- A minimal parser snippet in this ADR's diff (or a follow-up issue) should
  demonstrate that the seven new fields can be extracted with a single
  `grep '^generator_model:'` style invocation per artifact type.

## Related ADRs

- `0003-engine-parser-canonical-shape-contract.md` — engine parser contract;
  this change adds fields the parser already ignores, so the contract is
  unchanged.

## External References

- `docs/specs/2026-05-09-harness-value-analysis-design.md` (in the original
  motivating analysis branch) — drove the realization that Generator and
  Planner attribution is the limiting factor for retrospective analyses.
