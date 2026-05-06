---
task_id: retro-issue-batch-v1
task_title: Batch fix 17 retro-derived issues across engine, retro tooling, and protocol docs
date: 2026-05-06
checkpoints_total: 7
checkpoints_passed_first_try: 5
total_eval_iterations: 9
total_commits: 15
reverts: 0
avg_iterations_per_checkpoint: 1.3
---

# Retro — retro-issue-batch-v1

Fourth retro recorded in the public `harness-engineering-skills` repo. This
task closed seventeen open issues (`#8`, `#9`, `#12`–`#26`) — all filed by
prior retros (Apr 24, Apr 26, May 3) — in a single mega-batch on
`feat/retro-issue-batch-v1` ending in PR #28. Seven atomic checkpoints
covered three code surfaces: the `assemble-context` parser inside
`harness-engine.sh` (CP01), the retro filing helper
`scripts/file-retro-issue.sh` (CP02), the scope-check primitive (CP03), the
review-loop / full-verify coupling protocol (CP04), three new Spec Evaluator
pre-execution checks (CP05), the engine `autonomous_pr` config and PR-handoff
path (CP06), and three currently-implicit protocol surfacings (CP07).

5/7 checkpoints passed on first iteration. The two retries (CP01, CP03) are
documented in §What Worked Well as positive reinforcement of pre-existing
control mechanisms (REVIEW → 1-round mechanical fix; locate-then-modify halt
clause) — neither was a novel-pattern failure.

E2E: PASS. Review-loop: read-only branch-commits scope, four sequential
sessions across the day, final session `2026-05-06-091542-branch-commits`
returned `NO_FINDINGS`. Full-verify: skipped by config (`skip_full_verify:
true`). Filed issues this retro: see §Filed Issues.

The most consequential signal is the rule conflict: the spec's top-level
Success Criterion #2 ("Seven commits, one per checkpoint") was arithmetically
incompatible with multiple CP-level "Red precedes Green" acceptance criteria.
Three checkpoints flagged this as Rule Conflict Notes; the Generator silently
chose TDD discipline, which is the right default but is not a substitute for
the Spec Evaluator catching the contradiction at spec-review time. This is
recorded as a new pattern below and as Proposal 1.

---

## Observations

### Error Patterns

#### P1. [spec-internal-contradiction: commit-count-vs-tdd-sequence]

**Signal**: Three Rule Conflict Notes across three checkpoints
(CP01 iter-1, CP01 iter-2, CP02 iter-1) all reported the same conflict:

> The spec-level Success Criteria says the batch should have seven commits,
> one per checkpoint, while CP01 acceptance explicitly requires a red commit
> before a green commit. I followed the checkpoint-local TDD acceptance
> criterion so the Evaluator has concrete red/green commit evidence.

The actual commit count was **15** across 7 CPs. Five CPs required Red→Green
pairs by acceptance criterion (CP01, CP02, CP03, CP04, CP06). Five red+green
pairs alone forces ≥10 commits. Add the docs/edit commits and 15 is what you
get. Success Criterion #2 ("Seven commits") was unsatisfiable from the moment
spec v1 was approved.

**Frequency**: 1 task / 3 Rule Conflict Notes. Mechanically a single
contradiction surfacing in three checkpoints — but the surface that
should have caught it (Spec Evaluator) did not, and the surface that
*observed* it (Generator) responded by writing prose rather than halting.
This is the first time the Rule Conflict Notes channel has been used three
times in one task in the public repo (prior maximum was 1).

**Root cause**: The Spec Evaluator's checklist has Phase 5 evidence audits
and the three new CP05-shipped pre-execution checks (cross-CP artifact
ownership, literal localhost ports, executable SDK citations) but no
arithmetic-compatibility check between Success Criteria count claims and
CP-level commit-discipline acceptance criteria. The contradiction is
mechanical (count one, count the other, compare) but not currently any
agent's job.

**Why consumers missed it**: CP-level Evaluators correctly enforced the
local TDD red/green requirement. The top-level Success Criteria are not
re-derived at CP evaluation time — they are checked once by the Spec
Evaluator and then assumed valid. The Generator surfaced the conflict in
Rule Conflict Notes (the right channel) but the protocol does not currently
escalate Rule Conflict Notes back to spec revision; they accumulate as
post-hoc retro signal.

**Classification**: **Skill defect** in `harness-spec-evaluator`. The new
CP05-shipped checks set the precedent for "scan for mechanical
incompatibilities at spec-review time." This pattern fits the same family
and the same scanner architecture.

#### P2. [parser-axis-coverage-asymmetry: cp01-iter-1]

**Signal**: CP01 hardened three axes of the engine parser at once: (a) accept
bold-decorated `- **Type**:` form, (b) fail-loud on missing/invalid Type,
(c) ignore code-fenced and inline-backticked occurrences of `## Foo`-shape
headings inside checkpoint bodies. The iter-1 implementation covered (c) for
the section walker (heading detection) but not for the Type-extraction walker.
A fenced `- Type: frontend` sample inside a checkpoint body would have been
silently treated as the canonical Type. The Evaluator caught this as a
medium-severity, auto-resolvable REVIEW; iter-2 mirrored the `in_fence`
tracking into the Type loop and added a fifth fixture
(`scripts/test-assemble-context.sh`).

**Frequency**: 1 occurrence. Mechanically distinct from but conceptually
adjacent to PARSER-DECORATION-FRAGILITY (Apr 26 retro): "the parser has
an internal asymmetry between two walks of the same input."

**Root cause**: When a checkpoint hardens N orthogonal axes of a single
parser, the implementation order matters and walker-vs-walker symmetry is
load-bearing. The spec's acceptance criteria correctly named all three axes
and the fixture set covered them; the iter-1 implementation simply applied
the fence guard at one of two needed sites. Auto-resolvable on first review.

**Classification**: Implementation hygiene. No skill or rule change needed
— the Evaluator correctly downgraded to auto-resolvable, the fix took one
round, and the regression test now spans both walkers. Recording as a
positive pattern (REVIEW → 1-round mechanical fix recurring).

#### P3. [late-stage-coverage-gap-on-error-branches: scope-check]

**Signal**: After CP03 closed (verdict PASS, final SHA 6c25c83), the read-only
review-loop session 091135 surfaced one LOW finding: the regression test
`scripts/test-scope-check-base-fetch.sh` exercised the `git fetch` failure
path (origin pointed at a missing repo) but not the `git merge-base` failure
path (fetchable origin/main + a local orphan/unrelated HEAD). The engine's
fail-loud branches at `harness-engine.sh:319-322` (fetch) and
`harness-engine.sh:330-333` (merge-base) are now both real, but only one was
covered by the shipped test. Closed by `b12f949` (fix) + `ac0638e` (test).
The focused rerun session 091542 returned NO_FINDINGS.

**Frequency**: 1 occurrence in this task. Sibling pattern to
`IO-FAILURE-MODE-COVERAGE-GAP` from the Apr 26 retro (test harness exercises
adjacent failure paths but skips closely related branches). Recording as a
2nd-occurrence reinforcement of that pattern rather than as a new tag.

**Root cause**: CP03 spec acceptance #2 named *one* failure mode
("`git fetch` propagated"). The implementation correctly distinguished both
modes after CP03 evaluation feedback (the engine separates them at the line
level), but the test was scoped to the spec's named mode. This is the same
shape as `cp_fail` vs `mktemp_fail` from the Apr 26 retro: the test harness
matches the spec's enumeration of behaviors, not the implementation's
enumeration of branches. The read-only review-loop is the right surface to
catch this; it did.

**Classification**: Test-coverage gap, recurring sub-pattern of
IO-FAILURE-MODE-COVERAGE-GAP. Closed in-batch by `b12f949` + `ac0638e`. The
existing Monitoring proposal "Add `cp_fail` test fixture for cross-link
recovery branches" widens to cover this generalized case.

### Rule Conflict Observations

Three notes across CP01 iter-1, CP01 iter-2, CP02 iter-1 — all the same
underlying contradiction (Success Criterion #2 commit count vs CP-level
red/green TDD acceptance). See P1 above. The Generator's choice to follow
TDD discipline is correct; the protocol gap is that this contradiction
should have been caught by the Spec Evaluator before spec approval, not
observed three times by the Generator at execution time.

CP03 iter-2 logged an explicit non-conflict note: planner guidance
intentionally superseded CP03's iter-1 locate-only wording after the
Generator's Scope Expansion Request. This is the locate-then-modify halt
clause working as designed (see §What Worked Well) — not a rule conflict,
just protocol metadata for the Evaluator.

### What Worked Well

- **5-of-7 first-try checkpoint pass on a 17-issue mega-batch.** CP02, CP04,
  CP05, CP06, CP07 all passed on first iteration despite each touching
  different code surfaces (filing helper, protocol-quick-ref, agent prompt,
  engine config schema, three protocol sections). 71% first-try at this
  scope is the highest mega-batch first-try rate recorded in this repo.
- **REVIEW → 1-round mechanical fix recurring (CP01).** The Evaluator's
  auto-resolvable classification (severity ≤ medium, auto_fixable=true,
  requires_human_judgment=false) plus an exact `fix_hint` enabled iter-2 to
  apply the fence-tracking mirror to the Type walker plus a fifth fixture
  with no human guidance. Second occurrence of this pattern in the public
  repo (first was the Apr 24 task).
- **Locate-then-modify halt clause demonstrably prevents fabrication
  (CP03).** Generator iter-1 ran the locate grep across the candidate set
  named in Files of Interest. Zero matches → Generator HALTED with a Scope
  Expansion Request in `output-summary.md` rather than inventing the
  primitive. Planner expanded the candidate set; iter-2 located the actual
  site (engine `cmd_scope_check`), modified it (`6c25c83`), and shipped the
  regression test. This is the first occurrence of an explicit halt-clause
  preventing the engine from being invented from scratch in retro history.
- **Read-only review-loop as final-hardening pass (4 sessions across the
  day).** Sessions 085741, 090518, 091135, 091542 — earlier rounds caught
  the autonomous-PR branch-publishing gap (closed before final session) and
  the scope-check merge-base coverage gap (closed by `b12f949` + `ac0638e`).
  Final session returned NO_FINDINGS. Second occurrence of the
  "read-only review-loop as post-completion hardening" pattern canonized in
  the Apr 26 retro.
- **Two long-Proposed engine defects shipped fixes in-batch.**
  ENGINE-PARSER-FORMAT-DRIFT (Apr 24, issue #12) and STALE-BASE-REF-SCOPE-CHECK
  (Apr 24, issue #13) had been at "Proposed" since Apr 24. Both shipped
  inside this batch (CP01 and CP03 respectively). The
  PARSER-DECORATION-FRAGILITY and SCRIPT-RESILIENCE-OBSERVABILITY-GAP
  proposals from Apr 26 also shipped (CP02). Four "Proposed" rows in the
  index move to "Implemented" with this PR.
- **Mega-batch atomic-commit discipline held.** 15 commits across 7 CPs,
  zero reverts, every commit on the feature branch, every CP a clean
  TDD red/green pair where required. Conventional Commits prefixes applied
  (`feat(harness):`, `fix(harness):`, `docs(harness):`, `test(harness):`).
  No `Co-Authored-By` lines.
- **Engine version bump landed atomically inside CP06 alongside the
  schema change it represented.** `0.15.0 → 0.16.0` minor bump correctly
  classified — additive surface plus one behavioral correction (CP01's
  fail-loud on missing/invalid Type, surfacing previously-silent bugs
  rather than breaking valid specs).
- **Two ADRs (0003, 0004) shipped following the "ADR records rationale,
  schema lives in protocol-quick-ref.md" pattern from ADR-0001/ADR-0002.**
  Both ADRs cite source issues in their Context section and contain no
  duplicate schema text. The single-canonical-source-with-enforced-mirror
  invariant (`scripts/check-harness-target-repo.sh` exits 0) held across
  all four protocol-quick-ref.md edits in CP02/CP04/CP05/CP07.

---

## Recommendations

### Proposal 1: Spec Evaluator pre-execution check for commit-count vs TDD-sequence contradictions

- **Pattern**: SPEC-INTERNAL-CONTRADICTION-COMMIT-COUNT-VS-TDD (P1; new)
- **Severity**: medium
- **Status**: Proposed
- **target_repo**: harness
- **Issue-ready**: true
- **Root cause**: The Spec Evaluator's pre-execution checklist (including
  the three new CP05-shipped checks: cross-CP artifact ownership, literal
  localhost ports, executable SDK citations) has no arithmetic-compatibility
  check between top-level Success Criteria count claims and CP-level
  commit-discipline acceptance criteria. When a Success Criteria entry
  asserts an exact commit count `N` and one or more CPs require an explicit
  Red→Green pair (TDD readiness), the spec is internally inconsistent if
  `N` < (count of TDD-required CPs × 2). The Generator surfaced the
  contradiction three times in Rule Conflict Notes; the protocol response
  was prose rather than halt, because Rule Conflict Notes are descriptive,
  not blocking.
- **Drafted issue body**:
  ```text
  Title: Spec Evaluator should detect commit-count vs TDD-sequence contradictions

  retro-issue-batch-v1's spec v3 Success Criterion #2 said "Seven commits
  land on feat/retro-issue-batch-v1, one per checkpoint" while CP01, CP02,
  CP03, CP04, CP06 each had a "Red commit precedes Green commit" acceptance
  criterion. Five Red→Green pairs alone forces ≥10 commits; the actual
  count was 15. The Generator logged Rule Conflict Notes in three
  checkpoints (CP01 iter-1, CP01 iter-2, CP02 iter-1) and chose TDD over
  the Success Criterion. The contradiction is mechanical and was not
  caught at spec-review time.

  Fix: extend `harness-spec-evaluator.md` checklist with a new
  pre-execution check:

  - Name: cross-CP commit count vs TDD sequence contradiction
  - Severity: warning
  - Detection: when Success Criteria contains an entry asserting an
    explicit commit count N (regex match on phrases like "N commits land",
    "exactly N commits", "one commit per checkpoint" with N derivable),
    count the number of CPs whose acceptance criteria contain a "Red commit
    precedes Green commit" or equivalent TDD-sequence requirement. If N <
    (TDD_CPs × 2 + non-TDD_CPs), emit warning with suggested_fix:
    "Reconcile Success Criterion N with CP-level TDD requirements: either
    relax the count, drop the TDD-sequence acceptance, or restate the
    count as a minimum (≥)."
  - Suggested_fix template inline.

  Verification: add a fixture spec containing an explicit "Seven commits"
  success criterion and three CPs with red/green TDD acceptance; assert the
  Spec Evaluator emits the warning and the suggested_fix names the count
  mismatch. Add a second fixture asserting no warning when the count
  expression is a minimum (≥) or absent.

  Sibling note: CP05 shipped three pre-execution checks of the same
  family (cross-CP artifact ownership, literal localhost ports, executable
  SDK citations). This proposal extends the same scanner architecture.
  ```

### Proposal 2 (info-only): Lift IO-FAILURE-MODE-COVERAGE-GAP from Monitoring on 2nd occurrence

- **Pattern**: IO-FAILURE-MODE-COVERAGE-GAP (Apr 26 P3; recurring sub-pattern)
- **Severity**: low
- **Status**: Monitoring → ready for promotion on 1 more recurrence
- **Issue-ready**: false
- **Root cause**: The Apr 26 retro flagged that the test harness for
  `file-retro-issue.sh` had a `mktemp_fail` mode but not a `cp_fail` mode,
  even though both branches emit specific Filed Issues records. This task's
  scope-check coverage gap is the same shape: spec-named-mode covered, the
  sibling branch surfaced by the impl was uncovered until the read-only
  review-loop caught it. Two occurrences across two tasks, two different
  scripts. Cheap mechanical class of fix; promotable but not Issue-ready
  yet — the Apr 26 Proposal already drafted has not been filed.
- **Action**: leave as Monitoring. Promote to Proposed (Issue-ready) on
  the next recurrence, or bundle with the existing Apr 26 draft when filed.

### Skill Defect Flags

- **`harness-spec-evaluator` lacks commit-count-vs-TDD-sequence contradiction
  check.** New defect, target_repo: harness. See Proposal 1. The CP05
  pre-execution checks shipped in this task are the architectural template;
  this is the next pre-execution check on the same scanner.

### Lifecycle Updates Recommended for `index.md`

These are recommendations only; the human approver decides whether to
flip Pending Rule Proposal status from `Proposed` to `Implemented`. The
PR (#28) ships the code changes that match the drafted rule text in each
case, and the Filed Issues in the index point to the corresponding GitHub
issues that this PR closes.

| Pattern | Old Status | Recommended New Status | Evidence |
|---------|------------|------------------------|----------|
| ENGINE-PARSER-FORMAT-DRIFT | Proposed | Implemented | CP01: `7445c6b` + `3dc252a` close issue #12. Parser accepts canonical + bold form, fails loud on missing/invalid, robust to fenced code spans. |
| STALE-BASE-REF-SCOPE-CHECK | Proposed | Implemented | CP03: `6c25c83` (+ `b12f949`/`ac0638e` review-loop closure) closes issue #13. `cmd_scope_check` runs `git fetch origin <base>` and resolves against `origin/<base>`. |
| PARSER-DECORATION-FRAGILITY | Proposed | Implemented | CP02: `d45a522` closes issue #12 (filed Apr 26). `normalize_target_repo` strips one pair of decoration + trailing comment. |
| SCRIPT-RESILIENCE-OBSERVABILITY-GAP | Proposed | Implemented | CP02: `d45a522` adds `_gh_with_retry`, stdout summary line, `LABEL_READY=true` short-circuit, process-local label cache. |

---

## Filed Issues

This retro proposes one Issue-ready item (Proposal 1, target_repo: harness).
Filing is deferred to the orchestrator per task instructions. No GitHub
issues are filed by the retro agent itself. No CLAUDE.md edits are made.

PR closes 17 issues by reference (`Closes #N` in the PR body):
`#8`, `#9`, `#12`–`#26`. The three `target_repo: both` issues (`#16`, `#20`,
`#21`) are closed harness-side; the host-side cross-tracked URLs are
documented in the PR body and remain open in their respective host repos
per the spec's Out of Scope §1.
