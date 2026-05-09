# Parallel Cohort Execution

## Status

Accepted

## Date

2026-05-09

## Deciders

- Harness maintainers

## Context

Harness checkpoint execution has historically been linear even when adjacent
checkpoints are independent and file-disjoint. That protects state-machine
simplicity, but it makes wall-clock time scale directly with the number of
Generator and Evaluator turns.

This task introduces an explicit cohort model for safe parallel checkpoint
execution. The canonical schema remains in
[protocol-quick-ref.md](../../plugins/harness-engineering-skills/skills/harness/references/protocol-quick-ref.md)
and related protocol files; this ADR records the rationale for bundling cohort
dispatch, commit locking, runtime drift detection, and the cohort failure model
as one architectural decision.

## Decision Drivers

- Parallelism should be opt-in and mechanically visible in the spec.
- Existing specs without cohort metadata must keep serial behavior.
- The first concurrency primitive in the harness engine should have a small
  rollback surface and clear blast-radius boundaries.
- Cohort safety needs layered gates: deterministic preflight, spec-review
  warning checks, runtime drift detection, and post-work review-loop evidence.
- Canonical field names and marker tokens should stay mirrored across protocol,
  engine, and evaluator surfaces.

## Options Considered

- Explicit `parallel_group: <letter>` field on checkpoint metadata.
- Implicit DAG inference from `Depends on` and `Files of interest`.
- Single worktree plus `Files of interest` contract.
- Worktree-per-checkpoint execution.
- Runtime commit lock and drift detector in the engine.
- Cross-model spec-time validation for every cohort.

Implicit DAG inference was rejected because `Files of interest` is currently
reference information, not a complete ownership declaration. Silent inference
would make conflicts hard to debug and would make serial behavior depend on
parser judgment rather than an explicit spec choice.

Worktree-per-checkpoint execution was rejected because the commit-merge
complexity outweighs the parallelism it would unlock for non-disjoint
checkpoints that should remain serial anyway. The harness branch convention is
still a linear series of checkpoint commits, not a set of per-checkpoint merge
branches.

Cross-model spec-time validation was rejected because the existing post-E2E
review-loop already provides cross-model verification on the actual code. Adding
another cross-model gate before execution would defeat the wall-clock reduction
that parallel cohorts are meant to provide.

## Decision

Use four bundled pillars for parallel cohort execution:

- An explicit `parallel_group: <letter>` field (option B from the brainstorm)
  declares cohort membership; absent metadata remains the serial form.
- A single worktree plus `Files of interest` contract (option α) keeps the git
  model linear while requiring cohort members to declare disjoint file surfaces.
- A per-task commit lock primitive serializes shared state updates and provides
  the hook for generator commit boundaries.
- A runtime drift detector catches a cohort member that touches a peer member's
  declared files and reports the failure through `DRIFT_DETECTED` fix hints.

The cohort failure model is option-(i): if all members pass, the cohort passes;
if some members pass while another exhausts retries, the cohort enters the
partial-PASS escalation path instead of silently advancing.

## Consequences

- Positive: independent checkpoints can be dispatched concurrently without
  changing the serial behavior of existing specs.
- Positive: `enable_parallel_cohorts: false` remains a runtime rollback path for
  operators who need to disable multi-member cohorts.
- Positive: the option-(i) cohort partial-PASS failure model preserves
  autonomous execution for healthy members while forcing human input only when a
  mixed terminal cohort cannot be resolved mechanically.
- Negative: this is the first concurrency primitive in the harness engine, so
  future engine changes must account for lock ownership and drift attribution.
- Neutral: canonical schema and marker definitions remain in protocol docs; the
  ADR records rationale only.

## Validation

`scripts/check-parallel-cohort-rules.sh` is the mirror checker for this
decision. It verifies that the canonical cohort field, engine markers, and
commit-lock configuration key remain present across `protocol-quick-ref.md`,
`checkpoint-definition.md`, `harness-engine.sh`, and
`harness-spec-evaluator.md`.

## Related ADRs

- [ADR-0001: Convention Scout and Host Repository Documentation Gap](0001-convention-scout-and-host-repo-doc-gap.md)
- [ADR-0002: Retro Issue Routing](0002-retro-issue-routing.md)
- [ADR-0003: Engine Parser Canonical Shape Contract](0003-engine-parser-canonical-shape-contract.md)
- [ADR-0004: Review Loop Full-Verify Integration Audit](0004-review-loop-fullverify-integration-audit.md)

## External References

- None
