# Retro Issue Routing

## Status

Accepted

## Date

2026-04-26

## Deciders

- Harness maintainers

## Context

Harness Retro produces rule proposals and skill defect flags after a task
finishes. Step 11 of the execution protocol previously filed every
Issue-ready finding into the current host repository with the single
`harness-retro` label. That conflated two kinds of work: project-specific
cleanup owned by the host repository and harness protocol or agent defects
owned by this repository.

The problem became more visible as the harness was used from external
repositories. Skill consumers need a feedback loop that sends harness defects
back to the open-source harness maintainers, while project maintainers should
still receive rules and cleanup items that only affect their codebase.

ADR-0001 established the pattern of keeping canonical artifact schemas in
[protocol-quick-ref.md](../../plugins/harness-engineering-skills/skills/harness/references/protocol-quick-ref.md)
and referencing them from agents and protocols. This ADR applies the same
single-source rule to retro issue routing. The canonical field definition,
classification rule, and harness target constant live in
`protocol-quick-ref.md §issue-routing`; this ADR records the decision without
duplicating that schema.

## Decision Drivers

- Skill consumers need an open-source feedback loop for harness defects.
- Skill bugs and engine/protocol changes should be separated from project
  rules and code cleanup.
- The existing single-label `harness-retro` flow hides the responsible
  repository for each finding.
- The routing schema should have one canonical definition to avoid drift
  between agent prompts, execution protocol prose, and ADRs.
- The issue-filing step should stay autonomous and avoid a new user
  confirmation prompt for every retro item.

## Options Considered

- Per-finding `target_repo` field on every Issue-ready retro item.
- Auto-classify by retro section at filing time.
- Ask the user to confirm the destination repository after Retro.

Auto-classification was rejected because retro sections do not always map cleanly
to repository ownership; mixed findings and host documentation gaps can appear in
the same section. Asking the user was rejected because the execution protocol's
retro phase is autonomous and should not introduce a confirmation prompt for
each finding.

## Decision

Use a required per-finding `target_repo` field on every Issue-ready retro item.
The Retro agent writes the field when it drafts the finding. The Orchestrator
then routes Step 11 filing by that explicit field.

The schema, valid values, classification rule, and hardcoded harness target are
defined only in `protocol-quick-ref.md §issue-routing`. Agent and protocol files
reference that section rather than redefining the schema.

When a finding applies to both the harness and the host repository, the
Orchestrator files both issues and cross-links them after creation. If
ownership is genuinely ambiguous, Retro uses `both` and records the uncertainty
in the proposal body. Missing or invalid routing fields are recorded explicitly
in Filed Issues and skipped instead of silently defaulting to the host
repository. This remains autonomous: the Orchestrator does not pause for user
input during filing.

## Consequences

- Positive: Harness defects can be filed directly in the
  harness-engineering-skills repository where maintainers can act on them.
- Positive: Project-specific rule proposals continue to land in the host
  repository, preserving the current host-maintainer workflow.
- Positive: Mixed findings can be cross-filed without losing the relationship
  between the two issues.
- Positive: The routing schema remains centralized in
  `protocol-quick-ref.md §issue-routing`.
- Negative: Retro items now have one more required field, so missing-field
  validation is part of the filing path.
- Neutral: The harness target uses the existing `HARNESS_*` convention:
  `HARNESS_TARGET_REPO` has a hardcoded default in the canonical schema and can
  be overridden by callers that need a fork or future repository move.

## Validation

- `protocol-quick-ref.md §issue-routing` defines the required routing field and
  remains the only schema source.
- `harness-retro.md` requires the field by reference to the quick-ref section.
- `execution-protocol.md` Step 11 reads the field, routes host/harness/both
  cases, records missing-field skips, and records cross-filed issue URLs or
  partial failure state.
- Future retros with harness defects produce issue bodies that can be filed in
  this repository without moving project-specific items out of the host repo.

## Related ADRs

- [ADR-0001: Convention Scout and Host Repository Documentation Gap](0001-convention-scout-and-host-repo-doc-gap.md)

## External References

- None
