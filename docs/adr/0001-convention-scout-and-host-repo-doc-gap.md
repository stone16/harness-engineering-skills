# Convention Scout and Host Repository Documentation Gap

## Status

Accepted

## Date

2026-04-24

## Deciders

- Harness maintainers

## Context

Harness planning turns user intent into checkpoint acceptance criteria. Those
criteria are only as precise as the repository conventions available to the
Planner. When a host repository lacks clear verification or testing guidance,
the Planner currently has no structured way to distinguish weak wording from
missing source material.

That ambiguity causes two downstream problems. First, the Spec Evaluator can
label criteria as vague without saying whether the problem is the criterion
text or absent host documentation. Second, Retro can observe repeated gaps but
cannot turn them into issue-ready repository improvements.

Harness will add a read-only `harness-convention-scout` sub-agent that runs at
planning time, emits a `host-conventions-card.md`, and lets planning,
evaluation, and retro stages share one documented view of host-repository
convention evidence.

The canonical Card schema and probe priority list are maintained in
[protocol-quick-ref.md](../../plugins/harness-engineering-skills/skills/harness/references/protocol-quick-ref.md);
see the `host-conventions-card.md` section in that file. This ADR records the
rationale for the Scout/Card/MADR-draft pattern and intentionally does not
duplicate that tier list.

## Decision Drivers

- Acceptance criteria should be grounded in host-repository evidence when that
  evidence exists.
- Missing repository documentation should be attributed explicitly rather than
  silently converted into vague checkpoint wording.
- Retro findings should produce issue-ready improvements without prescribing a
  host repository's exact testing strategy.
- The Card format should have one canonical definition to avoid drift between
  agent prompts, protocol docs, and ADRs.
- The probe order should prefer high-authority documentation before inferred
  executable signals, because authority decays while implementation specificity
  increases.

## Options Considered

- Keep Planner-only convention discovery.
- Add Scout output as free-form prose.
- Add Scout output as a structured Card consumed by Planner, Spec Evaluator,
  and Retro.

## Decision

Use a dedicated read-only `harness-convention-scout` sub-agent during planning.
The Scout writes a structured `host-conventions-card.md` artifact. The Planner
uses the Card when drafting acceptance criteria, the Spec Evaluator uses it to
attribute vague criteria, and Retro uses it to produce issue-ready Host Repo
Documentation Gap findings.

When the host repository has an ADR culture, full-gap findings may be drafted
as MADR-style issue bodies. When no ADR culture exists, Retro emits a plain gap
report with a soft suggestion to adopt ADRs. Drift between documented
conventions and executable checks is always high priority.

## Consequences

- Positive: Planner and evaluator behavior becomes traceable to concrete
  repository evidence.
- Positive: Repeated documentation gaps become actionable issue bodies instead
  of implicit human cleanup work.
- Positive: The Card schema can evolve independently while consumers reference
  the same canonical source.
- Negative: Planning gains another asynchronous artifact and a timeout path
  that consumers must handle.
- Neutral: Harness defines its own ADR convention with this first ADR and a
  reusable template.

## Validation

- The Harness protocol quick reference contains the canonical
  `host-conventions-card.md` schema and probe priority list.
- The Scout agent references that canonical schema instead of redefining it.
- Planning protocol, checkpoint definition guidance, Spec Evaluator, and Retro
  each consume the Card only through the documented artifact contract.
- ADR-0001 keeps the rationale separate from the canonical Card definition to
  prevent three-way drift.

## Related ADRs

- None

## External References

- [MADR: Markdown Architectural Decision Records](https://adr.github.io/madr/)
- [Use Markdown Architectural Decision Records](https://adr.github.io/madr/decisions/0000-use-markdown-architectural-decision-records.html)
- [Claude Code subagents](https://docs.anthropic.com/en/docs/claude-code/sub-agents)
- [Claude Code Agent Skills](https://docs.claude.com/en/docs/claude-code/skills)
