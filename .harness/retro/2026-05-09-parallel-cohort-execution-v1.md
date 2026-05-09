---
task_id: parallel-cohort-execution-v1
task_title: Add concurrent (parallel) checkpoint execution to the harness orchestrator
date: 2026-05-09
checkpoints_total: 9
checkpoints_passed_first_try: 9
total_eval_iterations: 9
total_commits: 20
reverts: 0
avg_iterations_per_checkpoint: 1.0
---

# Retro — parallel-cohort-execution-v1

Fifth retro recorded in the public `harness-engineering-skills` repo. This
task introduced the **first concurrency primitive in the harness engine** —
`parallel_group` cohorts dispatched concurrently within a cohort, gated by a
per-task commit lock and a runtime drift detector that catches Generators
straying outside their declared `Files of interest` into a peer member's
territory. Nine atomic checkpoints across two surfaces: the protocol-doc
contract (CP01/CP06), the engine command surface (CP02/CP04/CP05/CP07/CP08),
the Spec Evaluator (CP03), and ADR + mirror-checker (CP09).

**9-of-9 first-try** at the checkpoint level. Twenty atomic commits, zero
reverts, zero Rule Conflict Notes across nine `output-summary.md` files. By
every signal the per-CP harness sees, this task is a clean run.

**The cross-model review loop tells a different story.** A single 3-round
review-loop session (peer = `claude` CLI, scope = `branch-commits`) surfaced
**12 real findings** — 2 critical, 3 major, 4 minor, 3 suggestion — every
one accepted, every one fixed in commit `3339f71`. Two of the critical
findings (drift detector inspected only `HEAD`'s commit; drift detector
misattributed peer commits under interleaving) were structural attribution
holes in the concurrency primitive itself. Three of the majors (`pass-checkpoint`
never read `drift-event.md`; `assemble-context` omitted peer file
restrictions; commit lock unreachable to Generator) were producer/consumer
or context-surface gaps that single-CP evaluation could not see, because
each surface satisfied the spec's per-CP acceptance criterion in isolation.

The post-review-loop delta E2E iter-2 at `3339f71` returned PASS — the first
occurrence in retro history of the **post-PASS runtime re-verification**
rule (issue #31, codified in protocol-quick-ref Apr 26) firing as designed:
review-loop touched runtime/protocol code, the harness re-ran a delta E2E
iteration, and the new SHA passed before the task was considered complete.

The most consequential signal is therefore not "we shipped 9-of-9" — it is
"sequential single-model CP evaluation cannot certify a cross-CP concurrency
contract; the cross-model review-loop is load-bearing for this class of
work." This is recorded as new pattern P1 below.

---

## Observations

### Error Patterns

#### P1. [concurrency-primitive-cross-cp-invariant-gap]

**Signal**: Review-loop session `2026-05-09-151155-branch-commits` surfaced
five findings (f1, f2, f3, f4, f5 — all severity ≥ major, including 2
criticals) on a branch where every CP `status.md` already read
`result: PASS` and every Evaluator session was fresh. The findings:

- **f1 (critical)**: `record_iteration_and_detect_drift` walked only
  `HEAD`'s commit. A multi-commit iteration could smuggle a drift commit
  past inspection if `HEAD` was clean. Fix: walk
  `HARNESS_COMMIT_LOCK_START_SHA → end_sha`. (engine
  `harness-engine.sh:1099-1104` → fixed via `record_iteration_and_detect_drift`
  range walk.)
- **f2 (critical)**: Without a public `with-commit-lock` window spanning
  `git commit` AND `end-iteration`, two Generators in cohort A could
  interleave such that A's drift inspection saw B's commit at HEAD. Fix:
  add public reentrant `with-commit-lock` CLI; engine wraps commit + drift
  detection in one attribution window via `HARNESS_COMMIT_LOCK_HELD`.
- **f3 (major)**: `cmd_pass_checkpoint` had no consumer for
  `iter-*/drift-event.md` — the artifact was written by the detector but
  never read at the gate, so a drifted iteration could still pass.
- **f4 (major)**: `cmd_assemble_context` did not emit peer cohort
  restrictions, so a Generator in cohort A had no in-context way to know
  what files belonged to peer B.
- **f5 (major)**: `acquire_commit_lock` was an internal helper with no
  public verb. The spec required Generators to commit under the lock, but
  the CLI surface to do so did not exist.

Five facets, all surfacing an underlying pattern: the **cross-CP
system-level invariant** ("commits committed inside lock A cannot be
misattributed to peer B"; "a drift artifact written at end-iteration must
be a hard pass-gate at pass-checkpoint"; "the Generator's context document
must carry the peer boundaries it cannot cross"; "if the spec says
'Generator runs X under the lock', a public CLI verb for X must exist")
was not a per-CP acceptance criterion of any single CP. Each individual CP
spec met its local criteria. The system invariant was distributed across
CP02 (lock primitive), CP05 (drift detector), CP07/CP08 (FAIL mode),
CP02/CP05's `cmd_assemble_context` integration, and the public CLI surface
documented in execution-protocol.md.

**Frequency**: 1 task / 5 facets. New pattern. Distinct from
SCOPE-SLIP-CROSS-CP-SEAM (which is about prose drift across sibling docs);
this is about **executable contract** drift across sibling commands when
the contract is a concurrency primitive.

**Root cause**: The Spec Evaluator's pre-execution checklist (which
includes the three CP05-shipped checks from the May 6 batch — cross-CP
artifact ownership, literal localhost ports, executable SDK citations —
plus the new `parallel_group_safety` warning shipped in this task) has no
**concurrency-primitive completeness audit**. When a spec introduces a
new concurrency primitive (lock, queue, dispatch, fork-join), there is a
fixed enumeration of system invariants that must be load-bearing across
the engine — but the spec's per-CP acceptance criteria can satisfy each
surface in isolation while leaving the system invariant un-tested. CP-level
Evaluators are scoped to their own CP's `Files of interest`; they cannot
detect that the artifact written by CP05 is never consumed by CP02's
`pass-checkpoint`.

**Why consumers missed it**: All 9 CP-level Evaluator sessions were unique
SDK sessions (verified at e2e/iter-2 §Checkpoint Status Roll-up: 9 distinct
session ids). The Evaluator skill cannot cross-cut surfaces because the
Evaluator's job description is "verify this CP's acceptance criteria,"
not "verify the system invariant this CP contributes to." The E2E phase
runs its data-flow audit, but iter-1's audit
(`.harness/parallel-cohort-execution-v1/e2e/iter-1/`) was anchored to the
spec's enumerated boundaries, not to "every executable contract this
concurrency primitive implies." The cross-model review-loop is the only
surface today that runs an adversarial sweep across the entire branch with
no scope boundary.

**Classification**: **Skill defect** in `harness-spec-evaluator` AND a
**process gap**. Two complementary fixes:

1. Spec Evaluator gains a `concurrency_primitive_completeness` warning
   that fires whenever a spec introduces a new lock, queue, dispatch, or
   fork-join primitive. The warning enumerates the system invariants that
   must each have an explicit producer-AND-consumer CP and a system-level
   fixture (not just a per-surface fixture).
2. Execution-protocol's seven-scenario "human input required" list is not
   the right surface for this — the right surface is the protocol's
   review-loop precedent. Make the cross-model review-loop **mandatory
   (not optional)** for tasks where the Spec Evaluator's
   `concurrency_primitive_completeness` warning fires. Today review-loop
   is configured per-repo via `cross_model_review` (SKILL.md L74). The
   precondition for marking the task complete should bind the two: if a
   concurrency primitive is introduced, `cross_model_review: true` is
   the only valid value.

#### P2. [parser-decoration-fragility recurrence (3rd task)]

**Signal**: f6 and f7 in the review-loop are bold-decorated form
rejections in two different parser sites:

- **f6 (minor)**: `parallel_group` regex at `harness-engine.sh:960` rejected
  `- **parallel_group**: A`. Fix: accept `(?:\*\*)?parallel_group(?:\*\*)?:`.
- **f7 (minor)**: `metadata_match` at `harness-engine.sh:987,1182` could
  leak decorated fields like `**Effort estimate**:` into the Files of
  interest list because the regex didn't tolerate the `**` decoration.

This is the **third task** in retro history with this pattern, fourth and
fifth facet:

- 2026-04-24 (convention-scout-and-doc-gap): **3 CPs** flagged
  `assemble-context` parser rejecting `- **Type**:` (ENGINE-PARSER-FORMAT-DRIFT,
  filed as issue #12, fixed in retro-issue-batch-v1 CP01).
- 2026-04-26 (retro-issue-routing): **2 facets** of `target_repo` extractor
  silently skipping decorated values (PARSER-DECORATION-FRAGILITY canonized,
  fixed in retro-issue-batch-v1 CP02).
- 2026-05-06 (retro-issue-batch-v1): CP01 iter-1 had a related
  parser-axis-coverage-asymmetry (fence-tracking on heading walker but
  not Type walker — different shape, same family).
- **2026-05-09 (this task): 2 facets** in two new regexes for two new
  metadata fields. Both authored from scratch, neither tolerated bold
  decoration on first ship.

**Frequency**: 4th overall task occurrence; pattern frequency now 3/10
tasks. The Apr 24 and Apr 26 fixes shipped retroactively; this task
**re-introduced** the same defect class in two new sites, then the
review-loop caught it. The fixes (`(?:\*\*)?` wrappers) are mechanical
and consistent.

**Root cause**: The "canonical plain-text shape" rule from ADR-0003 says
the spec author SHOULD write the plain form. The "compatibility-only
tolerance" rule says parsers SHOULD accept the bold form. The first rule
is published prominently in `protocol-quick-ref.md` and ADR-0003. The
second rule is **not codified as a parser default** anywhere a CP01/CP02
author can find it. Each new parser is hand-written. The regex `parallel_group:`
is a perfectly natural literal expression of "match the canonical form."
A defensive-by-default rule would have produced the `(?:\*\*)?` wrapper
on the first draft.

**Classification**: **Skill defect** at the protocol-quick-ref / harness-generator
seam. The codification target is `protocol-quick-ref.md` §Engine parser
patterns — add an explicit "Every metadata regex MUST tolerate
`(?:\*\*)?` around the field name and the value's leading/trailing tokens"
rule, with a one-line example pattern. The harness-generator's
implementation guidance for any parser CP should cite this rule by section
anchor.

#### P3. [adr-operational-doc-gap]

**Signal**: f12 (suggestion) flagged that ADR-0005 mentioned the
`DRIFT_DETECTED` marker in §Decision but no operational doc told the
operator what to DO when the marker fired. The fix added quick-reference
contract for `drift-event.md` to `protocol-quick-ref.md` plus
operational orchestration guidance to `execution-protocol.md`.

**Frequency**: 1 occurrence in this task. Sub-pattern of DOC-IMPL-DRIFT
(public-repo, currently 2 occurrences in index). Recording as a 3rd
occurrence reinforcement of that family rather than as a new tag.

**Root cause**: ADR-0005 followed the "ADR records rationale only" pattern
correctly. But the "rationale only" rule presumes the operational
contract for any new marker emitted by the engine lands in
`protocol-quick-ref.md` AND in `execution-protocol.md`, both of which
are operator-facing. The Planner enumerated the schema landing site
(protocol-quick-ref.md) but not the operational landing site
(execution-protocol.md). Auto-resolvable; review-loop caught it; fixed
in-batch.

**Classification**: Implementation hygiene + planning-checklist gap. Add
to harness-spec-evaluator: when a new engine output marker lands, both
schema (`protocol-quick-ref.md`) AND operator handling
(`execution-protocol.md`) MUST be enumerated as Files of interest in at
least one CP. Low-priority; current Monitoring tier.

#### P4. [enum-overspec]

**Signal**: f9 (minor) flagged that the cohort `status` enum was
documented as `pending|running|passed|partial-pass|aborted` but the engine
only ever emitted `pending|passed|partial-pass`. Two states (`running`,
`aborted`) were documented but unreachable. Fix: narrow the schema to the
emitted set.

**Frequency**: 1 occurrence. Adjacent to ENCODING-CORRUPTION-IN-DOCS in the
sense that "the documentation describes a state the implementation never
produces" is a class of latent contract drift, but this is the inverse
direction (doc says more than impl, vs impl says more than doc).

**Root cause**: Spec author's natural enumeration during schema design
included plausible-but-not-yet-implemented states. CP01's spec acceptance
named the enum verbatim from the spec; CP02's implementation was scoped
to the PASS path and the partial-pass path; no CP cross-checked the spec
enum against engine emit sites.

**Classification**: Implementation hygiene. Auto-resolvable. No skill
change; the existing `scripts/check-parallel-cohort-rules.sh` mirror
checker pattern is the right tier — just extend the enumerated checks to
include "every documented enum value must have a corresponding engine
emit site" for state machines.

### Rule Conflict Observations

**None.** Nine `output-summary.md` files, nine `## Rule Conflict Notes`
sections, all populated with `None.`. This is the **second task** in
retro history with zero rule conflicts (first was 2026-04-26
retro-issue-routing at 4-of-4). The signal: when the spec is
internally consistent (no commit-count vs TDD-sequence contradiction
class as in 2026-05-06; canonical Type shape uncontested per ADR-0003;
sequential-checkpoint invariant cleanly amended for cohort semantics per
host-conventions card §Contradictions), the Generator has no protocol
contradictions to surface. This was an expected outcome of the
host-conventions card's pre-flight identification of the
sequential-vs-cohort near-contradiction (recorded in the card's
`§Contradictions` section before spec authoring).

### What Worked Well

- **9-of-9 first-try checkpoint pass on a 9-CP concurrency-primitive task.**
  Third occurrence of the perfect first-try roll-up in this repo
  (2026-04-24 9/9, 2026-04-26 4/4, 2026-05-09 9/9). Notable because the
  task introduced the first concurrency primitive in the engine — the
  class of work where rookie mistakes are most expensive. Tight CP
  decomposition (each CP touched one engine surface), TDD discipline (10
  test-first commits + 9 feature/docs commits + 1 review-loop fix), and
  effort estimates matched reality.

- **Cross-model review-loop value (4th task occurrence; first to catch
  critical-severity findings).** Codex-Apr-24 caught encoding corruption,
  Codex-Apr-26 caught parser decoration narrowness, Codex-May-6 caught
  scope-check coverage gap. This task: claude-CLI-as-peer caught **2
  critical** concurrency-attribution holes plus 3 majors. The pattern
  has now caught a finding class that is not just "auto-resolvable
  REVIEW" — it caught structural primitives that would have shipped
  broken to downstream tasks. Promote this from "recurring positive
  pattern" to "load-bearing protocol element" in the index.

- **Post-PASS runtime re-verification rule fired as designed.** The rule
  shipped in retro-issue-batch-v1 (issue #31, codified Apr 26 in
  protocol-quick-ref.md L703-712: "if a review-loop session runs after an
  E2E PASS verdict and any accepted finding modifies runtime code [...]
  the harness must run a delta E2E iteration against the new SHA").
  iter-1 PASSED at `41317e1`. Review-loop accepted 12 findings, all
  modifying runtime code. iter-2 ran at `3339f71` and PASSED with full
  data-flow audit, full test re-run, full bash -n sweep, and explicit
  review-loop-fix verification table (e2e/iter-2/e2e-report.md L102-120).
  **First occurrence of this rule actually triggering** since it was
  codified. The mechanism worked exactly as written.

- **Canonical-source-with-enforced-mirror pattern (5th occurrence).**
  ADR-0001 established it; ADR-0002 reused it; ADR-0003 codified it;
  ADR-0004 generalized it (every ADR pairs with `scripts/check-*.sh`);
  ADR-0005 + `scripts/check-parallel-cohort-rules.sh` is the 5th case.
  No drift detected at any of the four mirrored surfaces
  (protocol-quick-ref, checkpoint-definition, harness-engine,
  harness-spec-evaluator). The pattern survives at the mega-batch scope
  AND at the new-concurrency-primitive scope.

- **Spec v3 host-conventions-card pre-flight caught the
  sequential-vs-cohort contradiction.** The card's §Contradictions section
  explicitly named that `checkpoint-definition.md:160-166`
  ("Checkpoints execute sequentially") would be read as forbidding
  parallelism unless the Planner amended it. CP01 amended it. The Spec
  Evaluator did not flag this as a contradiction — because the card
  did the work pre-spec, exactly as designed. First retro-recorded case
  of a host-conventions-card §Contradictions entry directly preventing
  a Spec Evaluator finding.

- **Atomic-commit discipline at concurrency-primitive scope.** 20
  commits across 9 CPs + 1 review-loop fix. Five CPs (CP02, CP04, CP05,
  CP07, CP08) followed strict Red→Green TDD pairs (10 commits). Four CPs
  (CP01, CP03, CP06, CP09) were docs/agent-prompt/ADR (single commit
  each, with a paired test or check script in the same commit where
  applicable). Conventional Commits prefixes applied (`feat(harness):`,
  `fix(harness):`, `docs(harness):`, `test(harness):`). Zero
  `Co-Authored-By` lines (verified in e2e/iter-2 §Working-tree
  Cleanliness).

- **Post-PASS review-loop convergence in 3 rounds.** 12 findings, all 12
  accepted, single repair commit at `3339f71`. Round 2 returned
  `CONSENSUS: All findings resolved`. Fresh-final round 3 returned
  `CONSENSUS: Approved` with one non-blocking observation. Zero rejected
  findings, zero INSIST cycles, zero escalations. Tight closure.

---

## Recommendations

### Proposal 1: Spec Evaluator concurrency-primitive completeness check + mandatory cross-model review

- **Pattern**: CONCURRENCY-PRIMITIVE-CROSS-CP-INVARIANT-GAP (P1; new)
- **Severity**: high
- **Status**: Proposed
- **target_repo**: harness
- **Issue-ready**: true
- **Root cause**: The Spec Evaluator's pre-execution checklist has no
  concurrency-primitive completeness audit. When a spec introduces a new
  lock, queue, dispatch, or fork-join primitive, there is a fixed
  enumeration of system invariants that must be load-bearing across
  multiple CPs (artifact producer paired with artifact consumer at gate;
  attribution window covers full operation; peer context propagated
  through assemble-context; public CLI verbs for every Generator-facing
  contract surface). Per-CP Evaluator sessions cannot cross-cut these
  surfaces; they verify their own CP's acceptance criteria. The
  cross-model review-loop is currently the only surface that audits the
  whole branch — and it is configured per-repo via `cross_model_review`,
  not bound to spec content.
- **Drafted issue body**:
  ```text
  Title: Spec Evaluator should detect concurrency-primitive specs and require mandatory cross-model review-loop

  parallel-cohort-execution-v1's review-loop session
  2026-05-09-151155-branch-commits surfaced 5 findings (severity ≥ major,
  including 2 criticals) on a branch where every CP `status.md` already
  read `result: PASS`. The findings — drift detector inspected only HEAD
  (f1, critical), drift detector misattributed peer commits under
  interleaving (f2, critical), `pass-checkpoint` never consulted
  `drift-event.md` (f3, major), `assemble-context` omitted peer file
  restrictions (f4, major), commit lock unreachable to Generator (f5,
  major) — were all cross-CP system invariants that single-CP
  evaluation cannot detect. Each surface satisfied its CP's acceptance
  criteria in isolation; the system invariant ("commits committed inside
  lock A cannot be misattributed to peer B") was not any single CP's
  job.

  Fix: extend `harness-spec-evaluator.md` checklist with two new
  pre-execution items:

  - Name: concurrency-primitive completeness audit
  - Severity: warning
  - Detection: when a spec introduces or modifies a lock, queue,
    dispatch, fork-join, or scheduler primitive (detectable via spec
    keywords: `lock`, `flock`, `mutex`, `cohort`, `queue`, `dispatch`,
    `fork`, `parallel`, `concurrent`, `worker`, `actor`), enumerate the
    following system invariants and verify each has both a producer CP
    AND a consumer CP in the spec:
    1. Every artifact written under the primitive has a hard pass-gate
       consumer (e.g., `pass-checkpoint` blocks if drift-event.md exists).
    2. Attribution windows cover full multi-step operations (e.g., the
       lock spans `git commit` AND `end-iteration`, not just `git commit`).
    3. Peer context propagates through `assemble-context` (the Generator
       sees what its peer is allowed to do, not just what it itself is
       allowed to do).
    4. Every Generator-facing contract surface has a public CLI verb
       (no internal-helper-only patterns where the spec implies a verb).
  - Suggested_fix: name the missing CP-pair (producer or consumer) and
    cite the system invariant by index.

  - Name: concurrency-primitive cross-model review requirement
  - Severity: warning
  - Detection: when the concurrency-primitive completeness audit fires,
    require `cross_model_review: true` for the task. If the resolved
    config (via `harness-engine.sh read-config`) has
    `cross_model_review: false` for a concurrency-primitive spec, emit
    a hard warning and block spec lock until the operator either
    (a) flips the config or (b) declares an explicit waiver in the spec
    body.
  - Suggested_fix: cite the resolved config layer where `false` was set
    and the override path.

  Verification: add a fixture spec containing `cohort` keyword + a
  cohort dispatch primitive but missing a consumer for a written
  artifact; assert the Spec Evaluator emits the completeness warning
  naming the missing consumer. Add a fixture spec with the same
  primitive but cross_model_review=false in the resolved config; assert
  the requirement warning fires.

  Sibling note: the May 6 batch's
  SPEC-INTERNAL-CONTRADICTION-COMMIT-COUNT-VS-TDD pre-execution check
  (issue #29) is the architectural template; this proposal extends the
  same scanner to system-invariant-shaped contradictions, not just
  arithmetic-shaped ones.
  ```
- **Drafted rule text** (for harness-spec-evaluator.md, added to the same
  block as `parallel_group_safety` in Phase 2 checklist):
  ```text
  - concurrency_primitive_completeness:
    severity: warning
    triggered_when: spec body contains any of the keywords lock | flock
      | mutex | cohort | queue | dispatch | fork | parallel | concurrent
      | worker | actor in a Scope or Acceptance criteria block.
    audit:
      - every artifact written under the primitive must have a hard
        pass-gate consumer in some CP's acceptance criteria.
      - attribution windows must cover the full multi-step operation
        (lock acquisition spans every step described in the spec, not
        just one).
      - peer context must propagate through assemble-context for any
        primitive that runs Generators concurrently.
      - every Generator-facing contract surface must have a public CLI
        verb in the spec, not just an internal helper.
    suggested_fix: name the missing producer-or-consumer CP-pair, cite
      the system invariant by index (1-4 above).

  - concurrency_primitive_cross_model_review:
    severity: warning
    triggered_when: concurrency_primitive_completeness fires AND the
      task's resolved config has cross_model_review: false.
    suggested_fix: flip the config to true, or declare an explicit
      waiver in spec body §Out of Scope citing the source of the waiver.
  ```

### Proposal 2: Codify defensive bold-decoration parser conformance

- **Pattern**: PARSER-DECORATION-FRAGILITY (3rd task occurrence in this repo;
  recurring; current index status `Implemented` for the prior fix sites)
- **Severity**: medium
- **Status**: Proposed
- **target_repo**: harness
- **Issue-ready**: true
- **Root cause**: Apr 24's ENGINE-PARSER-FORMAT-DRIFT and Apr 26's
  PARSER-DECORATION-FRAGILITY both shipped fixes (issue #12 closed; CP02
  of retro-issue-batch-v1). Both fixes were retroactive: a parser was
  shipped, a decorated form was rejected, the review-loop caught it, the
  parser was hardened. **This task re-introduced the same defect class
  in two new parser sites** (`group_match` for `parallel_group:` and
  `metadata_match` for the cohort body fields). Both authored from
  scratch, neither tolerated `**bold**` decoration on first ship. The
  underlying issue: the "compatibility-only tolerance" rule is not
  codified as a defensive default that a CP author can copy. ADR-0003
  states the canonical plain-text shape rule; the parser-side compatibility
  rule lives only in the existing parser's regex and in the fix-PR
  history.
- **Drafted issue body**:
  ```text
  Title: Codify defensive bold-decoration tolerance as a parser default

  PARSER-DECORATION-FRAGILITY recurred in parallel-cohort-execution-v1
  review-loop f6 and f7 in two new metadata regexes (group_match,
  metadata_match). This is the third task with the same defect class in
  this repo (Apr 24 ENGINE-PARSER-FORMAT-DRIFT, Apr 26
  PARSER-DECORATION-FRAGILITY, May 9 cohort-parser facets).

  Fix: add a §Engine parser patterns block to
  `protocol-quick-ref.md` that codifies the compatibility-only
  tolerance rule as a parser-side default, with a one-line example:

    Every metadata regex SHOULD tolerate (?:\*\*)? around the field
    name. Reference pattern:
      ^[[:space:]]*-[[:space:]]+(?:\*\*)?<field>(?:\*\*)?:[[:space:]]+(.+)$

  Then update harness-generator.md to cite this rule by section anchor
  in its parser implementation guidance, so any future "parse a new
  metadata field" checkpoint inherits the defensive default rather than
  hand-rolling a literal regex that only accepts the canonical form.

  Verification: add a fixture spec with bold-decorated metadata to
  `scripts/test-spec-format-parallel-group.sh` (already present in this
  task post-fix); on the next new-metadata-field CP, the Generator's
  parser regex starts with the (?:\*\*)? wrapper.
  ```
- **Drafted rule text** (for `protocol-quick-ref.md`, new §Engine parser
  patterns block):
  ```text
  ## Engine parser patterns

  Compatibility-only tolerance: every metadata regex in the engine MUST
  tolerate `(?:\*\*)?` around the field name. The canonical spec shape
  is plain text per ADR-0003; the parser-side default exists to absorb
  prose-author-introduced bold decoration without a fail-loud rejection.

  Reference pattern:

      ^[[:space:]]*-[[:space:]]+(?:\*\*)?<field>(?:\*\*)?:[[:space:]]+(.+)$

  Every parser CP whose Files of interest includes a new metadata regex
  cites this section in its acceptance criteria. The Spec Evaluator's
  Phase 2 checklist verifies the citation.
  ```

### Proposal 3 (info-only): Promote 9-of-9-with-zero-rule-conflicts to load-bearing positive pattern

- **Pattern**: 9-of-9 first-try with zero rule conflicts (3rd
  occurrence in repo: Apr 24 9/9, Apr 26 4/4, May 9 9/9)
- **Severity**: low (positive pattern reinforcement, not an issue)
- **Status**: Reinforcing
- **Issue-ready**: false
- **Root cause** (positive): The pattern correlates with three
  preconditions: (a) host-conventions-card §Contradictions block does
  pre-spec contradiction work; (b) spec author lifts CP scope to
  match a single engine surface per CP; (c) TDD test-first discipline
  inside each CP. When all three hold, Rule Conflict Notes
  population is zero across every CP.
- **Action**: Update Positive Patterns table in index.md.

### Proposal 4 (info-only): Promote cross-model review-loop value to load-bearing protocol element

- **Pattern**: Cross-model review value (4th task occurrence; **first to
  catch critical-severity findings**)
- **Severity**: low (process observation)
- **Status**: Reinforcing → consider promotion
- **Issue-ready**: false
- **Root cause** (positive): Per-CP Evaluator sessions are scoped to
  their own CP. The whole-branch adversarial sweep that the cross-model
  review-loop performs is the only surface today that audits cross-CP
  system invariants. In this task it caught two criticals plus three
  majors that would have shipped to downstream tasks if review-loop
  was disabled.
- **Action**: Pair with Proposal 1's `cross_model_review: true` mandate
  for concurrency-primitive specs. Update Positive Patterns table.

### Skill Defect Flags

- **`harness-spec-evaluator` lacks concurrency-primitive completeness
  audit AND lacks cross-model review-loop binding for primitive specs.**
  New defect, target_repo: harness. See Proposal 1. The May 6
  SPEC-INTERNAL-CONTRADICTION-COMMIT-COUNT-VS-TDD check (issue #29) is
  the architectural template — same pre-execution scanner, different
  contradiction shape (system-invariant rather than arithmetic).
- **`protocol-quick-ref.md` lacks codified defensive-parser-conformance
  rule.** Recurring defect (3 tasks), target_repo: harness. See Proposal 2.
  Today the rule lives only in shipped parser regexes; it is not
  citeable from a CP spec or a generator prompt.
- **harness-spec-evaluator's planning-checklist for new engine output
  markers does not enumerate the operator-facing landing site.** Sub-pattern
  observation; auto-resolvable in this task; promote on 1 more
  recurrence. (P3 above.)

### Lifecycle Updates Recommended for `index.md`

These are recommendations only; the human approver decides whether to
flip Pending Rule Proposal status. No prior `Proposed` row reaches
`Implemented` status from this task.

| Pattern | Old Status | Recommended New Status | Evidence |
|---------|------------|------------------------|----------|
| CONCURRENCY-PRIMITIVE-CROSS-CP-INVARIANT-GAP | (new) | Proposed (Issue-ready, target_repo: harness, severity high) | Proposal 1; review-loop f1-f5 surfaced 5 facets including 2 criticals on a 9/9 first-try task. |
| PARSER-DECORATION-FRAGILITY | Implemented (CP02 of retro-issue-batch-v1) | Implemented (recurrence noted) — Add **defensive-default codification proposal** as a separate Issue-ready row | Proposal 2; recurred in 2 new parser sites in this task. The prior fix sites remain Implemented; this is a new orthogonal issue (codify the rule, not just fix the sites). |
| Post-PASS runtime re-verification rule | Codified Apr 26 (issue #31) | Working-as-designed (1st actual trigger) | iter-2 e2e/iter-2/e2e-report.md re-ran full task scope at `3339f71` after review-loop modified runtime code. All 14 success criteria PASS. |

---

## Filed Issues

This retro proposes two Issue-ready items (Proposal 1 + Proposal 2, both
target_repo: harness). The orchestrator filed both after the retro agent
completed. No GitHub issues were filed by the retro agent itself. No
CLAUDE.md edits are made.

The branch's PR (forthcoming) will close prior retro-derived issues by
reference if/when filed; no prior open issues are slated for closure by
the parallel-cohort-execution-v1 PR itself, since this task's scope was
the cohort feature, not retro-issue-batch.

- Proposal 1 (harness, severity high, label not applied): https://github.com/stone16/harness-engineering-skills/issues/39
- Proposal 2 (harness, severity medium, label not applied): https://github.com/stone16/harness-engineering-skills/issues/40
