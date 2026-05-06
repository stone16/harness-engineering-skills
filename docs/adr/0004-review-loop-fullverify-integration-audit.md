# Review Loop Full-Verify Integration Audit

## Status

Accepted

## Date

2026-05-06

## Deciders

- Harness maintainers

## Context

Prior retros filed issues #17, #23, and #26 after review-loop completion and
full-verify evidence drifted apart. The recurring failure mode was not a missing
test runner; it was that review-loop could modify code, declare consensus, and
leave full-verify to rediscover whether the changed surface still satisfied the
task gates. Async lifecycle regressions were especially easy to miss when queues,
locks, events, or background tasks were constructed at import time instead of
inside the project lifespan boundary.

## Decision Drivers

- Review-loop evidence must be reusable by the later full-verify gate.
- Protocol text and review-loop operator instructions should carry the same
  rule names so drift is mechanically detectable.
- The rule should stay structural for this checkpoint because
  `full-verify/discovery.md` is task-local and has no stable global schema.
- Async lifecycle risks need a focused heuristic without forcing unrelated
  tasks into broad integration suites.

## Options Considered

- Leave review-loop and full-verify as independent phases.
- Teach the harness engine to parse every task's `full-verify/discovery.md`.
- Add a protocol-level mirror rule plus a structural checker that keeps the
  harness quick reference and review-loop instructions aligned.

## Decision

Codify `review-loop-fullverify-coupling` in `protocol-quick-ref.md` and mirror
the same rule keywords in the review-loop synthesis protocol. The initial
checker enforces the three stable keywords: `discovery-gate mirror`,
`post-fix integration audit`, and `async lifecycle heuristic`. Runtime
interpretation remains with the task operator because the discovery artifact is
task-specific.

## Consequences

- Positive: review-loop fix commits must carry enough evidence for full-verify
  to inspect the changed surface.
- Positive: async import-time lifecycle hazards become an explicit review-loop
  trigger instead of an accidental peer-review observation.
- Negative: review-loop reports are slightly longer when fixes are applied.
- Neutral: this does not introduce a global parser for
  `full-verify/discovery.md`; it enforces the shared rule vocabulary.

## Validation

`scripts/check-review-loop-fullverify-rules.sh` verifies that all three rule
keywords appear in `protocol-quick-ref.md`'s
`review-loop-fullverify-coupling` section and are mirrored downstream in the
review-loop skill instructions. The checkpoint evidence also runs a
deliberate-removal fixture to prove the checker fails when the protocol section
loses a required keyword.

## Related ADRs

- docs/adr/0001-convention-scout-and-host-repo-doc-gap.md
- docs/adr/0002-retro-issue-routing.md
- docs/adr/0003-engine-parser-canonical-shape-contract.md

## External References

- GitHub issues #17, #23, #26
