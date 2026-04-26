---
task_id: convention-scout-and-doc-gap
task_title: Add harness-convention-scout for host-repo convention discovery + MADR-draft doc-gap issues
date: 2026-04-24
checkpoints_total: 9
checkpoints_passed_first_try: 9
total_eval_iterations: 9
total_commits: 19
reverts: 0
avg_iterations_per_checkpoint: 1.0
---

# Retro — convention-scout-and-doc-gap

Second retro recorded in the public `harness-engineering-skills` repo. This
task introduced the `harness-convention-scout` sub-agent, the
`host-conventions-card.md` SSOT schema (P0–P9 probe tiers), the MADR ADR
template + first ADR, and wired all of it through planning-protocol, spec
evaluator, checkpoint-definition, retro taxonomy, and retro emission.

Nine checkpoints across three integration layers (agent definitions,
reference docs, ADR docs) all passed first try. E2E PASS. Review-loop
converged in 2 rounds plus a fresh-final consensus pass (8 findings, 0
rejected, 0 escalated). Full-verify was skipped by config (`skip_full_verify=true`).

**Branch context for this retro**: because this task implements the
Scout/Card system itself, there is no `host-conventions-card.md` artifact
for this task's own planning — the input is unavailable. Retro treats Card
input as absent and classifies this task as `scout_status != complete`
equivalent (P0–P5 absent) per the Scope note in `harness-retro.md`. No Card
findings are cited below.

---

## Observations

### Error Patterns

#### P1. [engine-parser: context-frontmatter-format-drift]

**Signal**: CP01, CP02, and CP03 each recorded the same Rule Conflict Note:
the engine-generated `context.md` frontmatter reported
`checkpoint_type: unknown`. The approved spec uses bold markdown labels
(`- **Type**: infrastructure`), but the engine's `assemble-context` parser
evidently expects plain `Type:` (or equivalent). The Generator fell back to
reading the checkpoint body directly to resolve type, which worked but
added an interpretation step on every checkpoint that uses the bold form.

**Frequency**: 3 occurrences inside a single task (CP01, CP02, CP03). CP03
explicitly names it "the recurring checkpoint_type: unknown parser issue"
— i.e. Generator had the same fallback three times.

**Root cause**: The harness engine's `assemble-context` markdown parser
does not recognize the bold-label variant of the required checkpoint
metadata line. The spec-authoring convention (`- **Scope**:`, `- **Type**:`,
`- **Depends on**:`, `- **Acceptance criteria**:`, `- **Files of interest**:`,
`- **Effort estimate**:`) is used by every recent spec in this repo and in
`stometa-skillset`'s private retros — the parser is simply lagging the
house style.

**Why consumers missed it**: Per-CP Evaluators don't audit the engine's
own frontmatter output as part of Tier 1. E2E doesn't either. The Generator
absorbed the defect silently via body-fallback interpretation. The
"Rule Conflict Notes" section is the only place it surfaced.

**Classification**: **Skill defect** in `harness-engine` (`assemble-context`
command). Either the parser should accept bold labels, or
`checkpoint-definition.md` should mandate the plain form.

#### P2. [sibling-protocol-drift: default-vs-conditional]

**Signal**: Review-loop f5 — `codex-mode.md` framed Scout invocation as
conditional while `planning-protocol.md` (after CP04) makes Scout the
default fork at brainstorm start. Both files describe the same Planner
behavior from different surfaces, and CP04 updated only planning-protocol
to the new default; codex-mode.md stayed on the older conditional
narrative. Review-loop caught the drift post-E2E.

**Root cause**: CP04's scope was `planning-protocol.md`; CP03's scope
included adding the agent name to `codex-mode.md` (a different change).
No CP had "update the Codex invocation surface to match the new default
fork/join" as an acceptance criterion — the default-vs-conditional framing
was a cross-file narrative invariant that no single CP owned.

**Classification**: Variant of the existing `SCOPE-SLIP-CROSS-CP-SEAM`
family (public repo, first occurrence was stometa-public-migration E2E
seam items). This instance was caught earlier (review-loop not E2E) so the
consequence was smaller, but the mechanism is identical: cross-cutting
narrative alignment without a single CP owner.

#### P3. [stale-base-ref: scope-check-false-positive]

**Signal**: CP09 Rule Conflict Note — local `main` was behind
`origin/main` by two commits. CP09's scope-diff acceptance criterion
(`git diff $(git merge-base main HEAD)..HEAD --name-only` touches only
approved files) falsely reported `review-loop/SKILL.md` as in-scope until
local `main` was fast-forwarded to `origin/main`.

**Root cause**: The scope-check command resolves `main` locally without
fetching. If local `main` is stale, `git merge-base main HEAD` returns an
earlier ancestor and the diff includes commits that are already merged
upstream — false positives. The engine-level contract in
`checkpoint-definition.md` does not document a `git fetch origin main`
prerequisite.

**Classification**: **Skill defect** in `harness-engine` /
`checkpoint-definition.md`. Fix is mechanical: either (a) the engine
resolves scope against `origin/main` after a `git fetch`, or
(b) documentation requires a fetch + fast-forward before running
scope-diff ACs.

#### P4. [encoding-corruption: u+fffd-in-release-docs]

**Signal**: Review-loop f1 (SKILL.md line 19 Planning→Generation→Evaluation
→Retro summary) and f2 (SKILL.md lines 102–134 File System Layout tree)
contained U+FFFD replacement characters where box-drawing characters were
intended. Both landed in release-authoritative documentation and survived
every per-CP and E2E grep-based check.

**Root cause**: A byte-encoding regression somewhere in the
author-write-commit chain. The authoring tooling emitted box-drawing
characters that were then stored as their replacement equivalents. Neither
per-CP Tier 1 nor E2E greps check for presence of U+FFFD.

**Classification**: Novel observation, low frequency (1 occurrence, 2
findings). **Monitoring** — if this recurs, add a Tier 1 `! grep -l
$'\xef\xbf\xbd'` check to the Evaluator's evidence sweep.

#### P5. [doc-impl-drift: prompt-input-omission]

**Signal**: Review-loop f6 — `planning-protocol.md`'s Spec Evaluator
prompt enumeration did not list `host-conventions-card.md` as an input,
even though CP06 made Phase 2 consume it for VAGUE attribution. The
contract said "Evaluator needs Card"; the prompt wiring said "Evaluator
receives X, Y, Z" — and X/Y/Z did not include the Card.

**Root cause**: Contract field added in one file (CP06 →
`harness-spec-evaluator.md`) but the companion wiring in
`planning-protocol.md`'s prompt-input list was not touched by any CP.
This is a classic `DOC-IMPL-DRIFT` variant (private-repo carry-over): a
new dependency surfaces in one file, the consumer surface doesn't get
synced.

**Classification**: Monitoring. If combined with P2 (sibling drift) and
prior repo signals, this could promote a `CROSS-FILE-CONTRACT-SYNC`
pattern covering "when adding a new input/output to a contract, all
wiring enumerations must be updated".

#### P6. [orphaned-directive / dead-path]

**Signal**: Review-loop f3 (Scout keyword-match rule had no binding to a
probe tier) and f4 (Retro decision table was unreachable when
`scout_status != complete` because `adr_culture_detected` was undefined
on that path). Both are **contract binding gaps**: text specifies a rule
or a decision table without a definition of where/how the rule applies or
what the default values are.

**Classification**: Low severity. Minor, fixed mechanically. Noted but
not proposed as a standalone pattern — sub-instance of P5 family.

### Rule Conflict Observations

#### RC1. Engine parser vs. house-style bold labels (P1 above)

Captured in three successive CP output-summary.md files. Generator
resolved correctly each time by falling back to the checkpoint body, but
the duplicated fallback burns interpretation cycles that a parser fix or
spec-authoring rule would eliminate.

#### RC2. Local main staleness vs. scope-check semantics (P3 above)

CP09 resolved correctly by fast-forwarding local `main` before running
the scope AC command. The scope AC's semantics *assume* local `main` is
current — the assumption is not documented.

### What Worked Well

- **9-of-9 first-try checkpoint pass**: magnitude + TDD discipline + the
  spec's CP decomposition all held. Effort estimates were accurate (mix
  of S and M; no L overflows). Zero evaluator iterations beyond the
  initial pass per CP.
- **CP09 wiring matrix with criterion indices**: the wiring-CP required
  each producer→consumer edge to cite the specific CP + acceptance-criterion
  number that validated the wiring. This turned the cross-CP reference
  graph into an auditable artifact. Downstream, E2E independently
  re-derived the same matrix from branch state and found every claim
  matched the consumer's actual `context.md` numbering (see e2e-report's
  "Matrix audit" table). Deliberate auditability is the inverse of the
  scope-slip pattern from the previous retro — this is the remediation
  working.
- **E2E data-flow audit depth**: the E2E report enumerates 8 explicit
  producer→consumer flows, each with Boundary type + Shape match? +
  Staleness risk? columns. The "Staleness risk" column independently
  identified the agent-rename coupling (flow #3) as a latent hazard —
  flagged for future work rather than blocking this task. This is the
  Data-Flow Audit doing exactly the job it was designed for.
- **Cross-model review value (3rd occurrence)**: Codex peer found two
  encoding defects (U+FFFD corruption) in release-authoritative files
  that grep-based evaluators cannot see, plus sibling-protocol drift
  that cross-cut CP ownership. First two occurrences (stometa-public-migration
  f1/f2/f4 and private-repo retros) established the pattern; this run
  reinforces it.
- **2-round review-loop convergence**: 8 findings, all accepted, all
  fixed in `03ceb76`. Round 2 returned 0 findings. Fresh-final consensus
  pass returned 0 additional findings. Efficient convergence with no
  INSIST cycles needed.
- **Zero reverts across 19 commits**: checkpoint gating continues to
  prevent premature integration. 2nd confirmation in this public repo.
- **Tool-agnostic invariant held**: CP09's `! grep -irE "optiminds|jest|
  vitest|playwright"` sweep passed cleanly; pre-existing leakage points
  (two mentions of `jest` / `vitest, pytest, etc.` in unrelated prose)
  were cleaned up during CP09 as part of the wiring pass.

---

## Cross-Model Insight

Codex's review-loop findings split into three categories that map to
distinct Evaluator-design gaps:

1. **Invisible-to-grep defects (f1, f2)** — encoding corruption. Per-CP
   Tier 1 evidence sweeps check presence of strings (grep patterns), not
   absence of corruption bytes. Adding a `! grep -l $'\xef\xbf\xbd'` or
   equivalent U+FFFD sweep to the Tier 1 evidence pass would catch this
   class cheaply. Tracking as improvement opportunity (Monitoring until
   second occurrence).

2. **Cross-file narrative drift (f5, f6)** — `codex-mode.md` conditional
   vs `planning-protocol.md` default (f5); Spec Evaluator prompt missing
   Card input (f6). Per-CP Evaluators enforce the CP's declared scope;
   "default-vs-conditional" and "contract-vs-wiring" are cross-file
   invariants with no single CP owner. This is the same root cause as
   `SCOPE-SLIP-CROSS-CP-SEAM` from the prior retro — caught earlier here
   (review-loop not E2E) because reviewers now know to look for it.

3. **Binding / dead-path gaps (f3, f4)** — Scout keyword rule without
   tier binding; Retro decision table unreachable on unavailable-Card
   path. These are **contract gaps**: text specifies *what* without
   *where/how/when*. Per-CP Evaluators verify the text is present; they
   don't verify the text is reachable/bindable. This is a candidate for
   a new Tier 2 check: "for every conditional or declarative rule
   introduced, verify its reachability path is explicit."

---

## Recommendations

### Proposal 1: Fix engine parser `checkpoint_type` bold-label handling

- **Pattern**: `[engine-parser: context-frontmatter-format-drift]` (P1)
- **Severity**: medium
- **Status**: Proposed
- **Root cause**: `harness-engine`'s `assemble-context` command writes
  `checkpoint_type: unknown` into `context.md` frontmatter when the spec
  uses the house-style bold label form (`- **Type**: infrastructure`).
  Every recent spec in this repo uses the bold form. Generators work
  around it via body-fallback interpretation. 3 occurrences in a single
  task makes this a skill defect, not an incident.
- **Drafted rule text** (this is a skill defect, not a CLAUDE.md rule —
  issue body for filing):
  ```
  Title: harness-engine assemble-context parser fails on bold **Type** labels

  harness-engine's assemble-context command emits `checkpoint_type: unknown`
  in context.md frontmatter when the approved spec uses the house-style
  bold-label checkpoint metadata form:

      - **Type**: infrastructure

  versus the plain form:

      - Type: infrastructure

  Observed 3 times in task `convention-scout-and-doc-gap` (CP01, CP02, CP03);
  Generator fell back to reading the checkpoint body directly each time.

  Fix options:
    (a) Update the parser to match /^\s*-\s*\*{0,2}\s*(Scope|Type|
        Depends on|Acceptance criteria|Files of interest|Effort estimate)
        \s*\*{0,2}\s*:/ so both forms parse identically.
    (b) Document in checkpoint-definition.md that the plain form is
        mandatory; Spec Evaluator rejects bold variants.

  Preference: (a), because the bold form is house style across specs.

  Verification: run the engine's assemble-context against a bold-form
  spec and confirm the emitted context.md frontmatter reports the
  correct checkpoint_type.
  ```
- **Issue-ready**: true

### Proposal 2: Scope-check must resolve against fetched origin/main

- **Pattern**: `[stale-base-ref: scope-check-false-positive]` (P3)
- **Severity**: medium
- **Status**: Proposed
- **Root cause**: CP09 wiring checkpoint's scope AC runs
  `git diff $(git merge-base main HEAD)..HEAD --name-only` and compares
  against a whitelist. If local `main` is behind `origin/main`, the
  merge-base includes commits already merged upstream and the diff
  reports false positives (files already in origin/main flagged as
  in-scope changes). This corrupts scope-discipline checks silently.
- **Drafted rule text** (skill defect — for filing as an issue):
  ```
  Title: harness-engine scope checks must refresh base ref before diffing

  harness-engine's scope-discipline checks (e.g. checkpoint-definition.md
  §Wiring Checkpoint scope AC) run `git merge-base main HEAD` against
  the local main ref without fetching. When local main is stale, the
  merge-base is an earlier ancestor and `git diff` reports already-merged
  files as in-scope changes — a silent false positive.

  Observed in task `convention-scout-and-doc-gap` CP09: review-loop/SKILL.md
  was falsely reported as in-scope until local main was fast-forwarded.

  Fix options:
    (a) Engine runs `git fetch origin main` before resolving the merge
        base, and uses `origin/main` as the base ref (not local main).
    (b) checkpoint-definition.md §Wiring Checkpoint documents the
        fast-forward prerequisite and Generators add it as a pre-AC step.

  Preference: (a), because engine-owned means Generators can't forget.

  Verification: deliberately rewind local main by two commits and run
  the scope AC; the fixed engine should still report zero violators.
  ```
- **Issue-ready**: true

### Proposal 3: Monitor `SIBLING-PROTOCOL-DRIFT` (variant of SCOPE-SLIP-CROSS-CP-SEAM)

- **Pattern**: `[sibling-protocol-drift: default-vs-conditional]` (P2)
- **Severity**: low-medium (this occurrence caught by review-loop, not
  E2E-escaped)
- **Status**: Monitoring
- **Root cause**: When two files narrate the same Planner behavior from
  different audiences (`planning-protocol.md` for Claude Code; `codex-mode.md`
  for Codex), a CP that updates one surface to a new default leaves the
  other surface stale. No CP owns the cross-file synchronization.
- **Drafted rule text** (draft — do not promote yet):
  ```
  When a checkpoint changes the default behavior of any cross-host
  protocol (planning, evaluation, review), the CP must explicitly list
  every sibling file that narrates the same behavior from a different
  host surface (Claude Code vs Codex vs Gemini vs review-loop). The
  CP's acceptance criteria sweep the sibling list for default/conditional
  alignment.
  ```
- **Issue-ready**: false (Monitoring only — single occurrence; combined
  with stometa-public-migration's SCOPE-SLIP-CROSS-CP-SEAM this is the
  second occurrence of the *family*, but the specific sibling-drift
  sub-pattern is first here. Promote if it recurs.)

### Proposal 4: Reinforce the wiring-matrix-with-criterion-index positive pattern

- **Pattern**: `[deliberate-auditability: wiring-matrix-cited]` (positive)
- **Severity**: n/a
- **Status**: Reinforce
- **Root cause / mechanism**: CP09's wiring AC required every
  producer→consumer edge to cite "the specific acceptance-criterion
  number in the consumer CP that validated the wiring". This forced the
  Generator to index into the consumer's criterion list, not paraphrase,
  and made E2E's "Matrix audit" trivially re-verifiable. The previous
  retro's P2 (`SCOPE-SLIP-CROSS-CP-SEAM`) is mechanically the inverse
  of this pattern. Worth canonizing for future wiring CPs.
- **Drafted guidance** (for `checkpoint-definition.md §Wiring Checkpoint`
  enhancement — not a CLAUDE.md rule, a protocol doc refinement):
  ```
  Wiring Checkpoint acceptance criteria that assert "X produces Y for
  consumer Z" MUST cite the specific acceptance-criterion number in Z's
  context.md that validates the wiring. Phrasing pattern:
    "<producer-CP> -> <consumer-CP> (criterion #N)"
  E2E evaluators can then independently re-derive the matrix from branch
  state, and rename/renumber of consumer criteria will break the wiring
  claim visibly rather than silently.
  ```
- **Issue-ready**: false (positive pattern reinforcement; adopt on next
  wiring CP, file as a follow-up only if the next wiring CP does not
  adopt it spontaneously.)

---

## Skill Defect Flags

#### SD1. harness-engine `assemble-context` bold-label parser gap (new)

**Skill**: `harness-engine` (`assemble-context` command)

Covered under Proposal 1 above. 3 occurrences in this task alone. Fix
preference is engine-side parser update so specs can use house style
without per-CP body-fallback.

**Status**: Actionable defect. Issue-ready.

#### SD2. harness-engine scope-check stale-base-ref (new)

**Skill**: `harness-engine` (scope-diff resolution) +
`checkpoint-definition.md` (documentation)

Covered under Proposal 2 above. Low realistic risk but is a latent
silent-corruption vector for scope discipline. Fix preference is engine
uses `origin/main` after fetch.

**Status**: Actionable defect. Issue-ready.

#### SD3. U+FFFD detection gap in Tier 1 evidence sweeps (new observation)

**Skill**: `harness-evaluator`

Per-CP Tier 1 checks enforce presence of expected strings but have no
sweep for corruption bytes (U+FFFD replacement characters or similar).
Review-loop caught two such defects in release-authoritative SKILL.md.

**Status**: Improvement opportunity (Monitoring). Promote to Actionable
if the same class reappears in another task. Cheap pre-emptive fix: add
`! grep -rl $'\xef\xbf\xbd'` sweep to the Tier 1 evidence bundle.

#### SD4. Per-CP Evaluator has no reachability check for conditional rules (new observation)

**Skill**: `harness-evaluator` (Tier 2)

Review-loop f3 and f4 caught text that was *present* (Tier 1 structural
greps passed) but *unreachable* (no binding to a tier / no default for
one case). This is a Tier 2 opportunity: when a CP introduces a
conditional, declarative rule, or decision table, verify that every
branch has a reachable population path.

**Status**: Improvement opportunity (Monitoring).

---

## Filed Issues

- Proposal 1 / SD1: https://github.com/stone16/harness-engineering-skills/issues/8
- Proposal 2 / SD2: https://github.com/stone16/harness-engineering-skills/issues/9

---

## Metrics Reference

- `checkpoints_total`: 9
- `checkpoints_passed_first_try`: 9 (CP01–CP09)
- `total_eval_iterations`: 9 (one per CP)
- `total_commits`: 19
- `reverts`: 0
- `avg_iterations_per_checkpoint`: 1.0
- `review_loop_rounds`: 2 + fresh-final consensus
- `review_loop_findings`: 8 total (8 accepted, 0 rejected, 0 escalated,
  0 deferred)
- `e2e_iterations`: 1 (PASS first pass)
- `full_verify`: SKIPPED (`skip_full_verify=true`)

PR: https://github.com/stone16/harness-engineering-skills/pull/7

## Execution Mode

Standard two-session mode (planning session produced the approved spec;
execution session ran CP01–CP09 + E2E + review-loop). No degraded-mode
compression.
