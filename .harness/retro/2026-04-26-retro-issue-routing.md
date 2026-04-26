---
task_id: retro-issue-routing
task_title: Route harness-retro issues to harness or host repo via per-finding target_repo
date: 2026-04-26
checkpoints_total: 4
checkpoints_passed_first_try: 4
total_eval_iterations: 4
total_commits: 13
reverts: 0
avg_iterations_per_checkpoint: 1.0
---

# Retro — retro-issue-routing

Third retro recorded in the public `harness-engineering-skills` repo. This
task introduced per-finding retro issue routing: a required `target_repo:
harness | host | both` field on every Issue-ready retro item, the canonical
schema in `protocol-quick-ref.md §issue-routing`, the executable filing
flow in `scripts/file-retro-issue.sh`, the canonical-default invariant
checker in `scripts/check-harness-target-repo.sh`, the protocol Step 11
update in `execution-protocol.md`, and ADR-0002 recording the decision.

Four checkpoints across two integration layers (canonical schema + harness
agent / protocol prose, and the supporting script + ADR) all passed first
try. E2E PASS. Review-loop ran in read-only mode against the branch-commits
scope (13 commits ahead of `origin/main`) and reported 8 follow-up findings
(0 critical, 0 warning, 4 minor, 4 suggestion); read-only by design, so no
acceptance/rejection/escalation accounting applies. Full-verify was skipped
by config (`skip_full_verify=true`).

**Branch context for this retro**: this task self-modifies the harness
repo's own retro routing surface. No `host-conventions-card.md` artifact
applies — input is unavailable. Retro treats Card input as absent and
classifies this task as `scout_status != complete` equivalent (P0–P5
absent), per the precedent set in the previous retro
(`2026-04-24-convention-scout-and-doc-gap`). No Card findings are cited.

**Review-loop framing**: the read-only run produced 8 follow-up triage
signals on the freshly-shipped infrastructure. None were blocking — the
task's branch had already cleared per-CP evaluation, E2E, and an earlier
review-loop pass (the read-only run is the post-fix audit). This retro
treats the 8 findings as second-tier hardening opportunities, not as
task-execution failures.

---

## Observations

### Error Patterns

#### P1. [parser-decoration-fragility: target_repo-extractor]

**Signal**: Review-loop f7 — the canonical extraction rule in
`protocol-quick-ref.md §issue-routing` says
`parse with ^- \*\*target_repo\*\*:[[:space:]]*(.*)$, trim, lowercase,
accept only harness/host/both`. A retro author who writes
`` - **target_repo**: `host` `` (decorated with backticks) or
`- **target_repo**: host  # ambiguous` (with a trailing comment)
produces a value that fails validation and is routed to the
`(skipped, invalid target_repo='...')` Filed Issues path. The retro file
looks fine to a human; the orchestrator silently skips the item.

**Frequency**: 1 occurrence (this task), but the contract is brand-new so
the surface is small. The same UX cliff will surface on every future
retro author who reaches for code-style decoration.

**Root cause**: The extraction regex captures everything from `:` to
end-of-line and validates the whole capture as the enum value. Any
decoration the author considered cosmetic becomes a silent invalidation.
The protocol-quick-ref does not document the decoration-stripping
contract (or the lack of one) — both the parser behavior and the author
expectation are implicit.

**Why consumers missed it**: The Tier 1 evidence sweep verifies the field
*exists*; nothing asserts the field's value parses to a valid enum
member. The Filed Issues record format `(skipped, invalid target_repo='<raw>')`
makes the failure auditable after the fact, but doesn't surface it
during retro authoring. The Spec Evaluator has no equivalent of "live
parse this line through the canonical regex" check.

**Sibling pattern**: Mechanically related to `ENGINE-PARSER-FORMAT-DRIFT`
from the previous retro (engine's `assemble-context` parser too narrow
for bold-label house-style metadata). Both are "harness parser is
stricter than what authors plausibly write." I'm tracking this as a
distinct pattern (`PARSER-DECORATION-FRAGILITY`) because the surface and
fix are different (protocol-doc parser regex + author guidance vs engine
markdown parser), but flagging the family connection in the index.

**Classification**: **Skill defect** in the harness retro routing
contract. Fix preference: harden the parser to strip a single pair of
surrounding backticks/quotes and trailing `# comments`, document the
decoration contract explicitly in `protocol-quick-ref.md §issue-routing`,
and add an evaluator-time live-parse check on retro Issue-ready items.

#### P2. [script-resilience-observability-gap: file-retro-issue.sh]

**Signal**: Three review-loop findings on the same script:

- f1 (minor): `gh issue create` and `gh issue edit` failures are treated
  as permanent. A single 5xx loses the cross-link permanently and only
  records a `(both, partial …)` Filed Issues line; maintainers must fix
  by hand.
- f2 (minor): The script silences `gh` stderr (`>/dev/null 2>&1` for
  labels, `|| url=""` for creates). The only artifact is the appended
  Filed Issues line; orchestrator and human auditors have no live
  observability on success or on the diagnostic that explains failure.
- f6 (suggestion): `ensure_label` does view→create→view per repo per
  filing — 2–3 `gh` round-trips even when the label exists. For
  `target_repo: both`, that's up to 6 label round-trips before the
  actual issue create.

**Frequency**: 3 facets in 1 task on 1 script. Together they describe
"freshly-shipped CLI helper, written for clarity and exhaustive
failure-mode enumeration in Filed Issues, has not yet had a resilience
+ observability + caching pass."

**Root cause**: The CP03 spec correctly enumerated 14 distinct Filed
Issues outcomes (every documented failure mode has a record format).
The implementation matched: every documented failure terminates by
writing the corresponding Filed Issues line. What was *not* in scope
was retry on transient errors, live observability for healthy runs, or
cache-aware label probes. Each of those is a separate hardening pass
the spec correctly deferred.

**Why consumers missed it**: Per-CP Evaluator validated the script
against the spec's acceptance mapping (which it passed). Tier 2 didn't
flag missing retries because the spec's behavior contract didn't claim
them. This is a **spec-shape gap**, not an evaluator-quality gap —
similar in structure to `CONFIG-DRIFT-PUBLIC-VS-PRIVATE`'s "no CP
explicitly owned the public-contract sweep" diagnosis from the
stometa-public-migration retro.

**Classification**: **Skill defect** (operational hardening) on the
harness retro filing helper. None of the three findings introduce a
correctness risk — the script's failure modes are all *recorded*; what
they lack is *recovery*, *observability*, and *efficiency*.

#### P3. [io-failure-mode-coverage-gap: test-file-retro-issue.sh]

**Signal**: Review-loop f3 — `file_cross_repo_issue` (lines 172–179 of
`file-retro-issue.sh`) and `annotate_partial_cross_file` (lines 119–127)
both have early-return branches on `cp` failure that emit specific
Filed Issues records (`(both, cross-link skipped, body copy failed)`
and `(both, annotation failed)`). The test harness exercises the
`mktemp_fail` adjacent path but has no `cp_fail` mode, so these
recovery branches and their canonical Filed Issues records are
unverified.

**Frequency**: 1 occurrence. Tightly scoped to two specific code
branches.

**Root cause**: The CP03 test harness was built to validate the
documented Filed Issues outcomes. `mktemp_fail` was added because the
spec called out the `mktemp` failure record format explicitly; `cp_fail`
was not separately spec'd as a test fixture even though the
corresponding Filed Issues records are documented. Same root mechanism
as P2: implementation matched the spec's enumeration of behaviors, but
some test fixtures track only the most prominent branches.

**Classification**: Test-coverage gap. Cheap mechanical fix: add a
`cp_fail` mode to the fake gh shim (or, more directly, chmod the body
file unreadable mid-run via a wrapper) and assert the exact
`(both, cross-link skipped, body copy failed)` line.

#### P4. [fragile-shell-extraction: check-harness-target-repo.sh]

**Signal**: Review-loop f4 — the canonical-default checker uses
`sed 's/^HARNESS_TARGET_REPO="${HARNESS_TARGET_REPO:-//; s/}"$//'`,
which only matches the exact `${HARNESS_TARGET_REPO:-VALUE}"` form.
If anyone reformats the canonical line to `${HARNESS_TARGET_REPO:=...}`
or splits across lines for readability, the checker either silently
extracts a malformed URL (and "passes" because both files share the
same broken form) or fails with a confusing error.

**Frequency**: 1 occurrence. Sibling to P1 (parser too narrow for
plausible reformatting).

**Root cause**: The checker was written defensively against
single-character drifts but is structurally coupled to one specific
bash expansion form. The script does perform a value-equality cross-check
between the quick-ref and the script copy — that catches most drifts —
but the *canonical-line-shape assumption* itself is a single point of
fragility.

**Classification**: Low severity (the value-equality cross-check makes
silent passes unlikely in practice). Fix preference: restrict the
extraction to a stricter regex that captures only the inner literal,
and emit a clear "canonical line format changed; update both files"
error when the pattern doesn't match.

#### P5. [doc-impl-drift-public-repo: ADR-claim-vs-script-duplicate]

**Signal**: Review-loop f5 — ADR-0002 states "The schema, valid values,
classification rule, and hardcoded harness target are defined only in
`protocol-quick-ref.md §issue-routing`." The reality is that
`scripts/file-retro-issue.sh:26` independently sets
`HARNESS_TARGET_REPO="${HARNESS_TARGET_REPO:-stone16/harness-engineering-skills}"`.
The duplication is intentional (a runtime executable copy that doesn't
require sourcing markdown) and is mitigated by
`scripts/check-harness-target-repo.sh`, but it is not eliminated. The
ADR overstates the property.

**Frequency**: 2nd occurrence in the public repo of the
`DOC-IMPL-DRIFT (public-repo)` family — the first was the
`planning-protocol.md` Spec Evaluator prompt missing
`host-conventions-card.md` as an input from convention-scout-and-doc-gap.
The two are mechanically distinct (one is "wiring enumeration not
updated", the other is "ADR claim overstates the property"), but both
are "doc surface drifted from implementation reality" and both fall
under the umbrella pattern.

**Root cause**: ADR drafting (CP04) wrote the canonical-source claim
*after* CP03 had already shipped the executable copy + checker
mitigation; the wording reflects the ideal "single source" state rather
than the practical "single source, with one enforced executable mirror"
state.

**Classification**: Documentation accuracy. Lightest fix: soften the
ADR wording to "...defined canonically in `protocol-quick-ref.md
§issue-routing`, with executable copies enforced by
`scripts/check-harness-target-repo.sh`."

#### P6. [governance-personal-namespace-default]

**Signal**: Review-loop f8 — the canonical default
`HARNESS_TARGET_REPO=stone16/harness-engineering-skills` points at
what looks like a personal account. If the skill is intended for
community use, every consumer who omits `HARNESS_TARGET_REPO` files
harness defects into one user's repo by default.

**Frequency**: 1 occurrence. Governance question, not a code defect.

**Root cause**: Repository was bootstrapped under a personal namespace
and has not yet moved to a GitHub organization. The default literal
encodes the current state of the world.

**Classification**: Governance / distribution question. No code change
required today, but worth a comment in `protocol-quick-ref.md` so
future contributors don't read the literal as a placeholder, and a
plan for the move-to-org transition.

### Rule Conflict Observations

None recorded. All four checkpoint output-summary.md files report
"Rule Conflict Notes: None." This is the first task in the public repo
to log zero rule conflicts across all checkpoints — `convention-scout-and-doc-gap`
recorded three (the bold-label parser + stale-base-ref family).
Notably, the engine-side bugs documented in that retro
(`ENGINE-PARSER-FORMAT-DRIFT`, `STALE-BASE-REF-SCOPE-CHECK`) are still
**Proposed** in the index; their absence here is consistent with their
being latent bugs (not triggered if specs use plain `Type:` form and
local main is current), not "bugs that have been fixed."

This is an interesting negative-evidence data point: latent parser
bugs only surface when authors happen to hit the trigger pattern. A
single task without rule conflicts shouldn't be mistaken for "the
engine bugs were resolved."

### What Worked Well

- **4-of-4 first-try checkpoint pass**: 13 commits across 4 CPs with 0
  reverts, 0 evaluator iterations beyond initial pass, 0 rule conflicts.
  Third strong "first-try discipline" signal in this repo (after
  9-of-9 in convention-scout and 3-of-4 in stometa-public-migration).
  Effort estimates were correctly tuned for documentation- and
  script-heavy CPs; nothing crossed magnitude thresholds.
- **Schema centralization succeeded by intent**: Three of four consumers
  (`harness-retro.md`, `execution-protocol.md`, ADR-0002) reference
  `protocol-quick-ref.md §issue-routing` rather than redefining the
  enum. The single executable exception (`file-retro-issue.sh`) is
  mitigated by `check-harness-target-repo.sh` — exactly the
  "canonical source, with executable copies enforced by a checker"
  pattern. Review-loop f5's complaint is about the ADR overstating
  this property, not about the property being violated.
- **Comprehensive failure-mode enumeration in Filed Issues**: The CP03
  spec called out 14 distinct Filed Issues record formats covering
  success, partial-create, partial-edit, mktemp-fail, body-copy-fail,
  cross-link-fail, label-not-applied, missing-target, invalid-target,
  and gh-CLI-unavailable. The implementation matched. This is the
  inverse of "silent failure" — every observable outcome has a
  canonical, parseable Filed Issues line.
- **Read-only review-loop on a fresh-final state added value without
  blocking**: The session ran post-fix on the branch-commits scope
  (13 commits ahead of main), produced 8 minor/suggestion follow-ups,
  and modified zero files. This validates the "read-only review-loop
  as post-completion triage" mode — it surfaced operational hardening
  ideas that wouldn't have justified another iteration cycle but are
  worth the next contributor's attention.
- **Test harness exercised at least one rare path**: The CP03 test
  harness has a `mktemp_fail` mode (review-loop f3 caught the missing
  `cp_fail` companion, but the harness pattern is sound). This is the
  "Stub-CLI shell transcript catches resolution bugs cheaply"
  positive pattern from the previous retro recurring here.
- **Behavior-mapping table preserved every old behavior**: CP02's
  output-summary includes a side-by-side mapping of every
  pre-existing harness-retro.md bullet to its new location. Word
  count dropped 861 → 691 with no behavior loss. This is a model
  example of *deliberate-auditability* applied to documentation
  rewrites — the kind of artifact that makes future retros' job
  easier when reasoning about "did anything change?"
- **ADR-0002 follows ADR-0001's heading order exactly**: CP04's
  acceptance check did a heading-by-heading comparison against
  `0000-TEMPLATE.md`. The template-conformance discipline established
  in convention-scout-and-doc-gap held on its first re-application.

---

## Recommendations

### Proposal 1: Harden retro `target_repo` extractor against decorated values

- **Pattern**: PARSER-DECORATION-FRAGILITY (P1; new)
- **Severity**: medium
- **Status**: Proposed
- **target_repo**: harness
- **Root cause**: The canonical extraction regex in
  `protocol-quick-ref.md §issue-routing` captures everything from `:`
  to end-of-line and validates the whole capture as the enum value.
  Authors writing `- **target_repo**: \`host\`` (backticks) or
  `- **target_repo**: host  # comment` (trailing comment) produce a
  silent skip into `(skipped, invalid target_repo='<raw>')`. The
  contract was just established — it's cheap to harden now and
  expensive to harden once retros across multiple consumers have set
  authoring habits.
- **Drafted issue body** (this is a skill defect; rule text is for the
  harness repo, not host CLAUDE.md):
  ```
  Title: harness retro target_repo extractor silently skips decorated values

  protocol-quick-ref.md §issue-routing canonicalizes target_repo
  extraction as:

      ^- \*\*target_repo\*\*:[[:space:]]*(.*)$, trim, lowercase, accept only
      harness/host/both

  A retro author who writes one of:

      - **target_repo**: `host`
      - **target_repo**: host  # ambiguous
      - **target_repo**: "both"

  produces a value that fails validation and is recorded as
  `(skipped, invalid target_repo='<raw>')`. The retro file looks
  syntactically correct to a human; the orchestrator silently skips
  the item. This is a UX cliff on a contract this task just shipped.

  Fix options:
    (a) Harden the parser to strip a single pair of surrounding
        backticks or quotes, and a trailing `#` comment after a
        whitespace boundary, before lowercasing.
    (b) Document explicitly in protocol-quick-ref.md that the captured
        value is the raw text between the colon and end-of-line; any
        decoration is treated as invalid. Add an authoring example.
    (c) Pick (a), and ALSO add an evaluator-time live-parse check that
        runs every Issue-ready proposal's target_repo line through the
        canonical regex and fails the retro CP if any value would not
        validate.

  Preference: (a) + (c). The parser should accept what authors
  plausibly write; the evaluator-time check turns silent skips into
  loud rejections at the moment the retro is authored, not after the
  filing run completes.

  Verification: add three test fixtures (backticked, quoted, trailing
  comment) and assert each one extracts to the bare enum value, and
  that an invalid value (e.g. `frontend`) still produces the canonical
  invalid record format.
  ```
- **Issue-ready**: true

### Proposal 2: Resilience + observability + caching pass on `file-retro-issue.sh`

- **Pattern**: SCRIPT-RESILIENCE-OBSERVABILITY-GAP (P2; new — bundles
  review-loop f1, f2, f6)
- **Severity**: medium
- **Status**: Proposed
- **target_repo**: harness
- **Root cause**: The CP03 spec correctly enumerated *what* to record
  for each failure mode (14 Filed Issues record formats). It did not
  scope *how* to recover from transient failures, *how* to surface
  live observability on healthy runs, or *how* to avoid redundant
  label round-trips. Each is a distinct hardening axis; together they
  describe "this freshly-shipped CLI helper has not yet had its
  operational pass."
- **Drafted issue body**:
  ```
  Title: file-retro-issue.sh needs resilience, observability, and
  label-cache pass

  Three operational hardening items on scripts/file-retro-issue.sh
  surfaced by review-loop on the retro-issue-routing branch:

  1) Transient gh failures are treated as permanent (review-loop f1).
     Wrap gh issue create / gh issue edit with a small retry helper
     (e.g. 3 attempts with 1s/2s/4s backoff). Final-outcome semantics
     and Filed Issues record formats stay identical.

  2) No stdout summary on success (review-loop f2). Echo a one-line
     outcome to stdout per invocation, e.g.
     `proposal=N target=harness url=... labels=ok`. Drop the blanket
     `2>&1` on the create call so genuine gh stderr surfaces on hard
     failures; keep `>/dev/null` to suppress the success spam. The
     Filed Issues file remains canonical; stdout is for live observability.

  3) Redundant label round-trips (review-loop f6). ensure_label runs
     view→create→view per repo per filing, costing 2–3 gh calls every
     invocation even when the label already exists. For target_repo:
     both that's up to 6 round-trips before the create. Add a
     process-local cache (file under ${TMPDIR}) keyed by (repo, label)
     so subsequent invocations within the same retro run skip the dance
     after the first success. Optionally accept a LABEL_READY=true env
     var for outer-orchestrator short-circuit.

  None of these introduce correctness risk. The script's failure modes
  are all recorded; what they lack is recovery, observability, and
  efficiency.

  Verification: extend test-file-retro-issue.sh with (a) a transient
  failure mode for the gh shim that succeeds on retry, asserting the
  retry helper recovers and the canonical success record is written;
  (b) a stdout-capture assertion on the per-invocation summary line;
  (c) a label-cache assertion that the second invocation in the same
  test run touches gh label only once total.
  ```
- **Issue-ready**: true

### Proposal 3: Add `cp_fail` test fixture for cross-link recovery branches

- **Pattern**: IO-FAILURE-MODE-COVERAGE-GAP (P3; new)
- **Severity**: low
- **Status**: Monitoring
- **target_repo**: harness
- **Root cause**: Two specific code branches in `file-retro-issue.sh`
  (cp failure in cross-link path; cp failure in annotation path) emit
  documented Filed Issues records that the test harness does not
  exercise. The corresponding `mktemp_fail` adjacent paths are tested.
- **Drafted issue body**:
  ```
  Title: test-file-retro-issue.sh missing cp_fail mode for cross-link
  branches

  scripts/file-retro-issue.sh emits two distinct Filed Issues record
  formats on cp failure:
    - "(both, cross-link skipped, body copy failed): <h-url> | <h-url>"
    - "(both, annotation failed): <url>"

  Neither branch is covered by tests. The mktemp_fail adjacent paths
  are covered. Add a cp_fail mode to the fake gh shim (or, more
  directly, a wrapper that chmod 000 the BODY_FILE mid-run after the
  first successful read) and assert each canonical record line is
  produced.
  ```
- **Issue-ready**: false

### Proposal 4: Stricter regex + clearer error in `check-harness-target-repo.sh`

- **Pattern**: FRAGILE-SHELL-EXTRACTION (P4; new — sibling to P1)
- **Severity**: low
- **Status**: Monitoring
- **target_repo**: harness
- **Root cause**: The checker's `sed` pattern is coupled to the exact
  `${HARNESS_TARGET_REPO:-VALUE}"` form. A reformatting of the canonical
  line silently extracts a malformed URL or fails with a confusing
  error. The value-equality cross-check between quick-ref and script
  catches most drifts in practice, but the line-shape assumption
  itself is fragile.
- **Drafted fix sketch**:
  ```
  Replace the current sed with a stricter pattern, e.g.:
      grep -oE 'HARNESS_TARGET_REPO="\$\{HARNESS_TARGET_REPO:-[^}"]+\}"'
  Then extract the inner literal via bash parameter expansion. On
  pattern miss, emit:
      "Canonical HARNESS_TARGET_REPO line in <file> does not match
       expected shape; if the line was intentionally reformatted,
       update scripts/check-harness-target-repo.sh first."
  ```
- **Issue-ready**: false

### Proposal 5: Soften ADR-0002 "single canonical source" wording

- **Pattern**: DOC-IMPL-DRIFT (public-repo; P5 — 2nd public-repo
  occurrence of the family, distinct sub-pattern from the
  `planning-protocol.md` prompt-input case)
- **Severity**: low
- **Status**: Monitoring
- **target_repo**: harness
- **Root cause**: The ADR overstates the canonical-source property by
  asserting "defined only in protocol-quick-ref.md §issue-routing"
  while `scripts/file-retro-issue.sh` holds an enforced executable
  duplicate of the harness-target literal. The duplication is
  intentional and mitigated, not eliminated; the ADR wording does not
  reflect that nuance.
- **Drafted fix**:
  ```
  Replace the ADR sentence
    "The schema, valid values, classification rule, and hardcoded
     harness target are defined only in protocol-quick-ref.md §issue-routing."
  with
    "The schema, valid values, and classification rule are defined
     canonically in protocol-quick-ref.md §issue-routing. The
     harness-target literal additionally has an executable mirror in
     scripts/file-retro-issue.sh, kept in sync by
     scripts/check-harness-target-repo.sh."
  ```
- **Issue-ready**: false

### Proposal 6: Annotate or relocate the personal-namespace `HARNESS_TARGET_REPO` default

- **Pattern**: GOVERNANCE-PERSONAL-NAMESPACE-DEFAULT (P6; new
  observation)
- **Severity**: low
- **Status**: Monitoring
- **target_repo**: harness
- **Root cause**: The canonical default `stone16/harness-engineering-skills`
  is a personal-account namespace. If the harness is consumed
  externally with `HARNESS_TARGET_REPO` unset, every harness defect is
  routed to one user's repo by default. The literal encodes the
  current namespace, not a placeholder.
- **Drafted fix**:
  ```
  Two-step plan:

  (a) Short term — add a comment in protocol-quick-ref.md §issue-routing
      adjacent to the HARNESS_TARGET_REPO line:
        "# stone16 is the current personal namespace. The literal will
         move to a GitHub organization before broader release; consumers
         can override with HARNESS_TARGET_REPO=<their-fork> in the
         interim."
  (b) Plan the move-to-organization transition. When it happens, run
      scripts/check-harness-target-repo.sh after updating both files.
  ```
- **Issue-ready**: false

### Proposal 7: Reinforce "freshly-shipped contracts deserve a hardening pass" as a positive workflow pattern

- **Pattern**: `[positive: read-only-review-loop-as-hardening-pass]`
- **Severity**: n/a
- **Status**: Reinforce
- **Root cause / mechanism**: The read-only review-loop session on this
  task's branch-commits scope produced 8 minor/suggestion findings on
  freshly-shipped infrastructure (filing script + extractor + ADR).
  None blocked merge. All 8 are operational follow-ups appropriate to
  *the next iteration*, not to *this task*. This validates the pattern
  of running a read-only review-loop after a feature passes E2E and
  before a follow-up task plans hardening work — the read-only output
  becomes the natural input to the hardening task's spec.
- **Drafted guidance**:
  ```
  When a task ships a brand-new infrastructure contract (a parser, a
  CLI helper, a script with new failure modes), the immediately-next
  task should consider: "is the read-only review-loop output from the
  previous task a candidate input for this task's brainstorm?" Treat
  the previous task's review-loop summary as a hardening backlog the
  Convention Scout can scan during planning. This turns the read-only
  review-loop's findings from passive triage signals into structured
  inputs for the next iteration.
  ```
- **Issue-ready**: false (positive pattern; adopt on next hardening
  task naturally — file as harness improvement only if the next
  retro/hardening cycle does not reach for the previous review-loop
  output spontaneously.)

---

## Skill Defect Flags

#### SD1. PARSER-DECORATION-FRAGILITY in retro `target_repo` extractor (new)

**Skill**: `harness-retro` (contract definition in
`protocol-quick-ref.md §issue-routing` + evaluator-time live-parse hook)

Covered under Proposal 1 above. 1 occurrence on a freshly-shipped
contract; the silent UX cliff justifies medium severity despite low
frequency. Sibling to ENGINE-PARSER-FORMAT-DRIFT from the previous
retro (both are "harness parser stricter than what authors plausibly
write"); flagging the family connection in the index but tracking as a
distinct pattern.

- **target_repo**: harness

**Status**: Actionable defect. Issue-ready.

#### SD2. SCRIPT-RESILIENCE-OBSERVABILITY-GAP in `file-retro-issue.sh` (new)

**Skill**: `harness-retro` (filing helper)

Covered under Proposal 2 above. 3 facets in 1 task on the same script:
no retry, no live observability, redundant label round-trips. Together
these are the "not-yet-hardened operational pass" of a freshly-shipped
CLI helper. None introduce correctness risk; together they degrade the
operator experience and add gh-API rate-limit pressure.

- **target_repo**: harness

**Status**: Actionable defect. Issue-ready.

#### SD3. IO-FAILURE-MODE-COVERAGE-GAP in `test-file-retro-issue.sh` (new observation)

**Skill**: `harness-retro` (test harness)

Covered under Proposal 3 above. Two recovery branches with documented
Filed Issues records lack a `cp_fail` test fixture; their adjacent
`mktemp_fail` paths are covered. Same root mechanism as SD2 — the
spec's enumeration of behaviors was matched by both implementation
*and* test fixtures, but the test fixtures cluster around the most
prominent branches.

- **target_repo**: harness

**Status**: Improvement opportunity (Monitoring). Promote to Actionable
if a regression in either branch produces an unobserved Filed Issues
malformation in a future task.

#### SD4. FRAGILE-SHELL-EXTRACTION in `check-harness-target-repo.sh` (new observation)

**Skill**: `harness-retro` (canonical-default checker)

Covered under Proposal 4 above. The checker's value-equality cross-check
catches most drifts in practice; the brittleness is in the
line-shape regex itself. Sibling to SD1 (parser too narrow for plausible
author/format input) at a different layer (verification script vs
protocol contract).

- **target_repo**: harness

**Status**: Improvement opportunity (Monitoring).

#### SD5. GOVERNANCE-PERSONAL-NAMESPACE-DEFAULT (new observation)

**Skill**: `harness-retro` / repository governance

Covered under Proposal 6 above. Distribution / governance question.
Worth annotation now and a transition plan for the move-to-organization
step.

- **target_repo**: harness

**Status**: Governance observation (Monitoring).

---

## Cross-Model Insight

The read-only Codex peer split its 8 findings into three categories that
recur across this repo's retro cycles:

1. **Operational hardening on freshly-shipped CLI helpers** (f1, f2, f6).
   These are the "not yet had its operational pass" findings — retry,
   observability, caching. The peer reads infrastructure code with an
   operator's eye and surfaces hardening backlog items the per-CP
   evaluator does not, because per-CP evaluators validate against spec
   acceptance criteria and the spec correctly scoped these as
   out-of-task.

2. **Parser/regex narrowness against plausible author input** (f4, f7).
   These are "the parser accepts less than authors plausibly write"
   findings. f7 in particular surfaces the same family as
   ENGINE-PARSER-FORMAT-DRIFT from the previous retro, but at a
   different layer — protocol-doc parser, not engine markdown parser.
   Per-CP evaluators verify the parser exists and matches the spec'd
   pattern; they don't probe it for under-specification against
   reasonable author decoration.

3. **Documentation accuracy and governance** (f5, f8). These are
   "doc says X; reality is X-with-an-asterisk" or "the literal encodes
   a state-of-the-world that may change." Per-CP evaluators check
   that documentation exists and links resolve; they don't audit
   doc-vs-reality nuance.

Cross-model peer review continues to surface defect classes that
grep-based evaluators don't catch — this is the **third occurrence** of
the cross-model-review-value positive pattern (after stometa-public-migration's
config drift sweep and convention-scout's encoding/sibling-drift catches).
The pattern is now load-bearing for the harness's review process: every
release-bound branch should expect a cross-model read-only pass to surface
exactly this class of follow-up.

---

## Filed Issues

(Pending Step 11 execution; this retro itself is the first to use the
new per-finding `target_repo` routing.)

---

## Metrics Reference

- `checkpoints_total`: 4
- `checkpoints_passed_first_try`: 4 (CP01–CP04)
- `total_eval_iterations`: 4 (one per CP)
- `total_commits`: 13
- `reverts`: 0
- `avg_iterations_per_checkpoint`: 1.0
- `review_loop_rounds`: 1 (read-only mode; status `read_only_complete`)
- `review_loop_findings`: 8 reported (0 critical, 0 warning, 4 minor,
  4 suggestion; 0 accepted, 0 rejected, 0 escalated, 0 deferred — all
  reported as follow-up triage signals per the read-only mode contract)
- `e2e_iterations`: 1 (PASS)
- `full_verify`: SKIPPED (`skip_full_verify=true`)

PR: (recorded by `pass-pr` step; this retro precedes that step.)

## Execution Mode

Standard two-session mode (planning session produced the approved spec;
execution session ran CP01–CP04 + E2E + read-only review-loop). No
degraded-mode compression.
