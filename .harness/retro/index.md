# Retro Index

Last updated: 2026-05-06

This is the public `harness-engineering-skills` repo retro index.
Cross-project patterns carried over from `stometa-skillset/.harness/retro/index.md`
are noted in the "Cross-Project Signals" section below but not counted
toward this repo's local frequency table — the goal is for public-repo
patterns to accumulate on their own evidence base.

---

## Frequency Table

Tracks error pattern frequency across tasks in *this* repo. Patterns with
3+ occurrences in last 10 tasks escalate to draft rules.

| Pattern Tag | Description | Occurrences (last 10 tasks) | Total Findings | Status |
|-------------|-------------|:---------------------------:|:--------------:|--------|
| SPEC-INTERNAL-CONTRADICTION-COMMIT-COUNT-VS-TDD | Top-level Success Criteria asserts an exact commit count `N` while one or more CPs require a Red→Green TDD pair, making the count arithmetically unsatisfiable. Generator surfaces in Rule Conflict Notes; Spec Evaluator does not catch at spec-review time. | 1 task / 3 CP notes | 3 | **Proposed** (severity: medium — Issue-ready, target_repo: harness) |
| CONFIG-DRIFT-PUBLIC-VS-PRIVATE | Imported-skill public surface advertises config keys/modes/peers that the host repo does not actually support | 1 | 6+ | **Proposed** (severity override: affected 7 files + 1 code branch on first occurrence) |
| ENGINE-PARSER-FORMAT-DRIFT | harness-engine `assemble-context` emits `checkpoint_type: unknown` when spec uses bold-label metadata (`- **Type**:` vs `- Type:`) | 1 task / 3 CPs | 3 | **Implemented** (CP01 of retro-issue-batch-v1: 7445c6b + 3dc252a; closes issue #12 — pending human verification) |
| PARSER-DECORATION-FRAGILITY | Harness retro routing extractor / verification regex too narrow for plausible author decoration (backticks, quotes, comments, reformatting) — silent skip on freshly-shipped contract (sibling to ENGINE-PARSER-FORMAT-DRIFT) | 1 task / 2 facets | 2 (f4, f7) | **Implemented** (CP02 of retro-issue-batch-v1: d45a522 — pending human verification) |
| SCRIPT-RESILIENCE-OBSERVABILITY-GAP | Freshly-shipped harness CLI helper has not had operational pass: no retry on transient failures, no live success-line observability, redundant API round-trips | 1 task / 3 facets | 3 (f1, f2, f6) | **Implemented** (CP02 of retro-issue-batch-v1: d45a522 adds `_gh_with_retry`, stdout summary line, `LABEL_READY=true` short-circuit, process-local label cache — pending human verification) |
| SCOPE-SLIP-CROSS-CP-SEAM | Cross-cutting narrative invariant has no single CP owner; sibling files drift (covers sibling-protocol-drift sub-pattern) | 2 | 3 | Monitoring |
| SPEC-GAP-CLI-VERB-REALITY | Spec AC invokes a CLI verb as a gate but spec body describes a shape the CLI rejects; discovered only at execution time | 1 | 1 | Monitoring |
| IMPORT-HYGIENE-DEFECT-PROPAGATION | Byte-for-byte import carries latent defects from the source into the destination's public surface | 1 | 2 | Monitoring |
| STALE-BASE-REF-SCOPE-CHECK | Scope-diff ACs run `git merge-base main HEAD` against local main without fetching; stale local main produces false positives | 1 | 1 | **Implemented** (CP03 of retro-issue-batch-v1: 6c25c83 + b12f949 + ac0638e; closes issue #13 — pending human verification) |
| ENCODING-CORRUPTION-IN-DOCS | U+FFFD replacement characters in release-authoritative docs slip past grep-based evidence sweeps | 1 | 2 | Monitoring |
| DOC-IMPL-DRIFT (public-repo) | New dependency added to one file; companion wiring enumeration in sibling file not updated (variant of private-repo pattern). Sub-pattern observed: ADR claim overstates "single canonical source" while runtime enforces an executable mirror via checker script. | 2 | 3 | Monitoring (2nd occurrence is a distinct sub-pattern, not the same wiring-omission instance) |
| IO-FAILURE-MODE-COVERAGE-GAP | Test harness exercises adjacent failure paths (e.g. mktemp_fail) but skips closely related branches (e.g. cp_fail) whose Filed Issues records are documented. 2nd occurrence (retro-issue-batch-v1, CP03 review-loop f1): test covered fetch-failure path but not merge-base-failure path until read-only review-loop caught it (closed in-batch by b12f949 + ac0638e). | 2 | 2 | Monitoring (promote on 1 more recurrence; cheap mechanical fix class) |
| GOVERNANCE-PERSONAL-NAMESPACE-DEFAULT | Canonical default literal encodes a personal-account namespace that may need a future move-to-organization plan | 1 | 1 (f8) | Monitoring (governance observation, not code defect) |

---

## Pending Rule Proposals

| Proposal | Pattern | Status | Action |
|----------|---------|--------|--------|
| Spec Evaluator pre-execution check for commit-count vs TDD-sequence contradictions | SPEC-INTERNAL-CONTRADICTION-COMMIT-COUNT-VS-TDD | **Proposed** | Issue-ready (target_repo: harness): extend `harness-spec-evaluator.md` with a `severity: warning` cross-CP check on count claims vs TDD acceptance (Proposal 1 in 2026-05-06 retro) |
| Imported-Skill Public-Contract Sweep | CONFIG-DRIFT-PUBLIC-VS-PRIVATE | **Proposed** | Issue-ready: sweep all advertised contract surfaces during decoupling CP |
| CLI Verb Reality-Check in Spec-Review | SPEC-GAP-CLI-VERB-REALITY | **Proposed** | Issue-ready: live-probe CLI gates before spec lock |
| Fix engine `assemble-context` bold-label parser | ENGINE-PARSER-FORMAT-DRIFT | **Implemented** | Shipped in CP01 of retro-issue-batch-v1 (7445c6b + 3dc252a); closes issue #12. Pending human verification before retiring from this table. |
| Scope-check must resolve against fetched origin/main | STALE-BASE-REF-SCOPE-CHECK | **Implemented** | Shipped in CP03 of retro-issue-batch-v1 (6c25c83) plus review-loop coverage closure (b12f949 + ac0638e); closes issue #13. Pending human verification. |
| Harden retro `target_repo` extractor against decorated values | PARSER-DECORATION-FRAGILITY | **Implemented** | Shipped in CP02 of retro-issue-batch-v1 (d45a522). Pending human verification. |
| Resilience + observability + caching pass on `file-retro-issue.sh` | SCRIPT-RESILIENCE-OBSERVABILITY-GAP | **Implemented** | Shipped in CP02 of retro-issue-batch-v1 (d45a522): `_gh_with_retry`, stdout summary line, `LABEL_READY=true`, process-local label cache. Pending human verification. |
| Add `cp_fail` test fixture for cross-link recovery branches | IO-FAILURE-MODE-COVERAGE-GAP | Monitoring | Draft only — 2nd occurrence (retro-issue-batch-v1 CP03 scope-check merge-base coverage gap) closed in-batch; promote on 1 more recurrence (Proposal 3 in 2026-04-26 retro; reinforced 2026-05-06) |
| Stricter regex + clearer error in `check-harness-target-repo.sh` | PARSER-DECORATION-FRAGILITY (sibling) | Monitoring | Draft only — promote if a canonical-line reformat silently passes the checker (Proposal 4 in 2026-04-26 retro) |
| Soften ADR-0002 "single canonical source" wording | DOC-IMPL-DRIFT (public-repo) | Monitoring | Draft only — low-cost copy fix; bundle with next ADR/contract revision (Proposal 5 in 2026-04-26 retro) |
| Annotate / plan move-to-org for `HARNESS_TARGET_REPO` default | GOVERNANCE-PERSONAL-NAMESPACE-DEFAULT | Monitoring | Governance observation; promote to action when distribution scope changes (Proposal 6 in 2026-04-26 retro) |
| Cross-CP Narrative Seam Check | SCOPE-SLIP-CROSS-CP-SEAM | Monitoring | Promote at 1 more task with same pattern (2/3 now) |
| Sibling-Protocol Sweep Rule | SCOPE-SLIP-CROSS-CP-SEAM | Monitoring | Draft only — promote if sibling-drift sub-pattern recurs (Proposal 3 in 2026-04-24 retro) |

---

## Pending Principle Proposals

None.

---

## Rule Lifecycle Tracker

No rules promoted to CLAUDE.md yet. Proposals above await human review.

**Implementation transitions (2026-05-06)**: four previously-Proposed rule
proposals shipped fixes in PR #28 (`retro-issue-batch-v1`):
ENGINE-PARSER-FORMAT-DRIFT (CP01, closes #12),
STALE-BASE-REF-SCOPE-CHECK (CP03, closes #13),
PARSER-DECORATION-FRAGILITY (CP02),
SCRIPT-RESILIENCE-OBSERVABILITY-GAP (CP02). Status moved to
**Implemented** in the Pending Rule Proposals table; rows remain in this
index until the human approver retires them. The new
SPEC-INTERNAL-CONTRADICTION-COMMIT-COUNT-VS-TDD proposal is the first
post-batch addition awaiting filing.

---

## Skill Defect Log

| Observation | Skill | Status | Source |
|-------------|-------|--------|--------|
| Per-CP Evaluator has no "imported-but-untouched code" audit hook | harness-evaluator | Improvement opportunity | stometa-public-migration retro |
| `pass-review-loop` does not bind session to harness task identity (rounds.json lacks `harness_task_id` + reviewed-diff SHA) | harness-engine | **Actionable defect** (feature-sized) | stometa-public-migration retro (from Codex f3) |
| `max_rounds` verdict with zero escalated findings indistinguishable from consensus; no `consensus_patches` accounting in gate | harness-engine + review-loop | **Actionable defect** | stometa-public-migration retro |
| `assemble-context` parser fails on bold `**Type**:` labels → `checkpoint_type: unknown` | harness-engine | **Actionable defect** (Issue-ready) | convention-scout-and-doc-gap retro (3 CPs) |
| Scope-diff ACs run against local `main` without fetching; stale local main → false-positive scope violators | harness-engine / checkpoint-definition.md | **Actionable defect** (Issue-ready) | convention-scout-and-doc-gap retro (CP09) |
| Tier 1 evidence sweeps don't detect U+FFFD replacement characters in docs | harness-evaluator | Improvement opportunity | convention-scout-and-doc-gap retro (review-loop f1/f2) |
| Per-CP Evaluator has no reachability/binding check for conditional rules / decision tables | harness-evaluator (Tier 2) | Improvement opportunity | convention-scout-and-doc-gap retro (review-loop f3/f4) |
| Retro routing `target_repo` extractor silently skips decorated values (backticks/quotes/trailing comments) — UX cliff on freshly-shipped contract | harness-retro (protocol-quick-ref + evaluator live-parse hook) | **Actionable defect** (Issue-ready) — `target_repo: harness` | retro-issue-routing retro (review-loop f7) |
| `file-retro-issue.sh` lacks retry on transient `gh` failures, lacks live success-line stdout, and does view→create→view label dance per filing (up to 6 round-trips for `target_repo: both`) | harness-retro (filing helper) | **Actionable defect** (Issue-ready) — `target_repo: harness` | retro-issue-routing retro (review-loop f1/f2/f6) |
| `test-file-retro-issue.sh` has no `cp_fail` mode — two recovery branches with documented Filed Issues records are unexercised | harness-retro (test harness) | Improvement opportunity — `target_repo: harness` | retro-issue-routing retro (review-loop f3) |
| `check-harness-target-repo.sh` `sed` extraction couples to one specific bash expansion form; reformatting the canonical line silently extracts a malformed URL | harness-retro (canonical-default checker) | Improvement opportunity — `target_repo: harness` | retro-issue-routing retro (review-loop f4) |
| ADR-0002 "single canonical source" wording overstates property — script holds enforced executable mirror | harness-retro (ADR copy edit) | Improvement opportunity — `target_repo: harness` | retro-issue-routing retro (review-loop f5) |
| `HARNESS_TARGET_REPO` canonical default points at personal namespace `stone16/...`; needs annotation + move-to-org plan | harness governance | Governance observation — `target_repo: harness` | retro-issue-routing retro (review-loop f8) |
| `harness-spec-evaluator` lacks pre-execution check for cross-CP commit-count vs TDD-sequence contradictions; surfaced 3× in one task as Rule Conflict Notes that the protocol does not escalate | harness-spec-evaluator | **Actionable defect** (Issue-ready) — `target_repo: harness` | retro-issue-batch-v1 retro (Proposal 1) |

---

## Positive Patterns (Reinforce)

| Pattern | Description | Occurrences |
|---------|-------------|:-----------:|
| Script behavior test for infra CPs | Stub-CLI shell transcript catches resolution bugs cheaply | 2 |
| 3-tier path math on first try | `$SCRIPT_DIR/../../..` + `BASH_SOURCE[0]` — right first time | 1 |
| Cross-model INSIST cycle | Peer INSIST converts rejected-on-scope findings into real fixes inside round budget | 1 |
| E2E auto_resolvable REVIEW → 1-round mechanical fix | Exact fix_hint → mechanical generator application → clean re-evaluation | 1 |
| Zero reverts across task | Checkpoint gating prevents premature integration | 3 |
| Cross-model review value | Codex finds classes grep-based evaluators miss (encoding corruption, sibling drift, orphaned directives, parser narrowness, operational hardening backlog) | 3 |
| Wiring matrix with criterion index | CP09-style wiring AC cites specific consumer criterion #; E2E re-derives independently | 1 |
| E2E data-flow audit with staleness-risk column | 8-flow audit identifies latent rename-coupling hazards before they bite | 1 |
| 9-of-9 first-try checkpoint pass | Accurate effort estimates + tight CP decomposition + TDD discipline compounds to zero eval iterations | 1 |
| 4-of-4 first-try with zero rule conflicts | Smaller-scoped doc/script task lands cleanly; no engine-bug triggers hit; canonical-source-with-enforced-mirror pattern adopted on first try | 1 |
| 2-round review-loop convergence | 8 findings resolved in 2 rounds + fresh-final; 0 INSIST, 0 escalation | 1 |
| Read-only review-loop as post-completion hardening pass | Read-only run on branch-commits scope produces operational follow-ups without blocking merge; output becomes natural input for next hardening task's brainstorm | 1 |
| Comprehensive failure-mode enumeration in Filed Issues | 14 distinct record formats covering success, partial-create, partial-edit, mktemp-fail, body-copy-fail, cross-link-fail, label-not-applied, missing-target, invalid-target, gh-CLI-unavailable | 1 |
| Behavior-mapping table for documentation rewrites | Side-by-side mapping of every old behavior bullet → new location preserves audit trail through 861→691 word reduction | 1 |
| Canonical source with enforced executable mirror | Single canonical schema in protocol-quick-ref.md + value-equality checker script keeps ADR/agent/protocol consumers in sync without runtime markdown sourcing | 1 |
| 5-of-7 first-try on a 17-issue mega-batch | Largest mega-batch retro-derived issue closure in this repo (PR #28: 7 atomic CPs, 15 commits, 0 reverts, 71% first-try). Demonstrates the spec-shaped mega-PR works at this scope. | 1 |
| Locate-then-modify halt clause prevents fabrication | CP03 iter-1 ran the locate grep across the named candidate set, found zero matches, and HALTED with a Scope Expansion Request rather than inventing the missing primitive. Planner expanded the candidate set; iter-2 located and modified the actual site. First explicit halt-clause use in retro history. | 1 |
| 4 review-loop sessions across one day as final-hardening iteration | Read-only review-loop run sequentially across the day; earlier rounds caught autonomous-PR branch-publishing gap and scope-check merge-base coverage gap; final session NO_FINDINGS. 2nd occurrence of the read-only-review-loop-as-post-completion-hardening pattern. | 2 |
| Long-Proposed engine defects shipped fixes in-batch | ENGINE-PARSER-FORMAT-DRIFT and STALE-BASE-REF-SCOPE-CHECK were Proposed since Apr 24; both shipped fixes (CP01, CP03) inside this batch. PARSER-DECORATION-FRAGILITY and SCRIPT-RESILIENCE-OBSERVABILITY-GAP from Apr 26 also shipped (CP02). Demonstrates the retro→Proposed→Implemented loop closes within a few weeks at the mega-batch scope. | 1 |
| ADR-records-rationale-only invariant held across two new ADRs | ADR-0003 and ADR-0004 cite source issues, contain rationale only, and let canonical schema live in protocol-quick-ref.md. The Apr 26 retro's positive-pattern "canonical-source-with-enforced-mirror" recurred without violation. | 2 |

---

## Cross-Project Signals (context only, not counted locally)

Patterns observed in the private `stometa-skillset` retros that may recur
here. Listed for pattern-matching awareness; do not count toward this repo's
frequency table until they actually occur in a public-repo task.

- **DOC-IMPL-DRIFT** (3+ in private retros, promoted) — public-repo's
  `DOC-IMPL-DRIFT (public-repo)` row above is the first local occurrence
  (review-loop f6 in this task). `CONFIG-DRIFT-PUBLIC-VS-PRIVATE` is also
  a subfamily.
- **VALIDATION-LAXITY** (3+ in private retros, promoted) — the missing
  phase guards in stometa-public-migration's f2 are arguably an instance;
  did not count locally since the root cause was *imported defect*, not
  migration-new laxity.

---

## Retro History

| Date | Task ID | Retro File | Key Signal |
|------|---------|------------|------------|
| 2026-05-06 | retro-issue-batch-v1 | [retro](2026-05-06-retro-issue-batch-v1.md) | SPEC-INTERNAL-CONTRADICTION-COMMIT-COUNT-VS-TDD (new, Issue-ready, target_repo: harness, 3× in one task as Rule Conflict Notes); 5/7 first-try on 17-issue mega-batch (15 commits, 0 reverts); 4 previously-Proposed patterns implemented in-batch (ENGINE-PARSER-FORMAT-DRIFT, STALE-BASE-REF-SCOPE-CHECK, PARSER-DECORATION-FRAGILITY, SCRIPT-RESILIENCE-OBSERVABILITY-GAP); IO-FAILURE-MODE-COVERAGE-GAP 2nd occurrence (review-loop f1: scope-check merge-base coverage); locate-then-modify halt clause demonstrably prevented fabrication (CP03); 4-session read-only review-loop converged to NO_FINDINGS |
| 2026-04-26 | retro-issue-routing | [retro](2026-04-26-retro-issue-routing.md) | PARSER-DECORATION-FRAGILITY (new, Issue-ready, sibling to ENGINE-PARSER-FORMAT-DRIFT); SCRIPT-RESILIENCE-OBSERVABILITY-GAP (new, Issue-ready, 3 facets in one task); IO-FAILURE-MODE-COVERAGE-GAP (new, Monitoring); GOVERNANCE-PERSONAL-NAMESPACE-DEFAULT (new, Monitoring); DOC-IMPL-DRIFT (public-repo) 2nd occurrence (sub-pattern: ADR overstates "single canonical source"); 4/4 first-try + zero rule conflicts + zero reverts + 13 commits; read-only review-loop as post-completion hardening pass canonized; canonical-source-with-enforced-mirror positive pattern canonized |
| 2026-04-24 | convention-scout-and-doc-gap | [retro](2026-04-24-convention-scout-and-doc-gap.md) | ENGINE-PARSER-FORMAT-DRIFT (new, 3x in one task, skill defect); STALE-BASE-REF-SCOPE-CHECK (new, skill defect); ENCODING-CORRUPTION-IN-DOCS (new, Monitoring); 9/9 first-try + 2-round review-loop + zero reverts; wiring-matrix-with-criterion-index positive pattern canonized |
| 2026-04-16 | stometa-public-migration | [retro](2026-04-16-stometa-public-migration.md) | CONFIG-DRIFT-PUBLIC-VS-PRIVATE (new, severity-override); SCOPE-SLIP-CROSS-CP-SEAM (new, monitoring); SPEC-GAP-CLI-VERB-REALITY (new, monitoring); 3 skill defects filed (review-loop task-identity binding, max_rounds vs consensus ambiguity, imported-code audit hook) |

## Filed Issues
- Proposal 1 (harness): https://github.com/stone16/harness-engineering-skills/issues/12
- Proposal 2 (harness): https://github.com/stone16/harness-engineering-skills/issues/13

### retro-issue-batch-v1 (2026-05-06)

PR #28 (`feat/retro-issue-batch-v1`) closes 17 retro-derived issues by
reference: `#8`, `#9`, `#12`–`#26`. Three issues marked `target_repo: both`
(`#16`, `#20`, `#21`) are closed harness-side; host-side cross-tracked URLs
remain open in their respective host repos per the spec's Out of Scope §1.

Issue filing for the new SPEC-INTERNAL-CONTRADICTION-COMMIT-COUNT-VS-TDD
proposal (target_repo: harness) was handled by the orchestrator after the
retro agent completed.
- Proposal 1 (harness, label not applied): https://github.com/stone16/harness-engineering-skills/issues/29
