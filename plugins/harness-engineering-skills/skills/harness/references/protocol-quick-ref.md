# Harness Protocol — File Format Quick Reference

All files use YAML frontmatter + markdown body. Write files exactly per these formats.

---

## spec.md

```yaml
---
task_id: <uuid-short>
title: <human-readable title>
version: <N, increment on revision>
status: draft | reviewing | approved
branch: <git branch name>
created: <ISO timestamp>
updated: <ISO timestamp>
---
```

Sections: Goal, Success Criteria, Checkpoints, Technical Approach, Out of Scope, Open Questions.

**Checkpoint heading format (REQUIRED by engine parser):**
```markdown
### Checkpoint 01: <title>
- Scope: ...
- Acceptance criteria: ...
- Depends on: ...
- Type: frontend | backend | fullstack | infrastructure
```
Each checkpoint MUST use `### Checkpoint NN: <title>` heading (zero-padded number). The engine uses this exact pattern for `assemble-context` extraction.

### Evidence Requirements (enforced by Spec Evaluator Phase 5)

Whenever the spec asserts that a decision, threshold, design, or value was
validated empirically, the claim MUST carry **inline sanitized evidence**.
This applies to any of the following phrase patterns appearing in the spec
body (Goal / Success Criteria / Technical Approach / Checkpoint descriptions):

- `validated via`
- `tested via`
- `verified against`
- `benchmarked at`
- `measured at`
- `reverse-engineered`

Standalone tool names (`curl`, `psql`, etc.) are intentionally **not** scanned —
they frequently appear in execution-guidance prose (e.g. "Generator should run
`curl ...`") and would produce false positives.

**Required inline shape** — directly adjacent to the claim:

1. The exact `command` that was run (sanitize: replace secrets/tokens/hostnames
   with `REDACTED` or dummy values).
2. An `output snippet` proving the claim — **≤ 20 lines by default**.
3. An **ISO-8601 capture date** (e.g. `2026-04-15` or `2026-04-15T14:32:10Z`)
   so a reader can tell when the evidence was gathered.

**Overriding the line limit** — when a longer snippet is genuinely necessary
(e.g. a benchmark table), place an HTML comment marker on its own line
**immediately before** the snippet:

```markdown
<!-- evidence-limit: 60 -->
```

- `N` MUST be `≤ 100`. Values above 100 are rejected by Phase 5 as noise that
  belongs in a separate evidence file, not inline in the spec.
- The marker applies only to the immediately following snippet; the default
  20-line cap resumes for subsequent claims.

**Enforcement** — The Spec Evaluator's Phase 5 "Validation Claim Audit" scans
for the phrase patterns above. Any match lacking command + output snippet
(within the applicable line limit) + ISO-8601 date is emitted as a
`severity: critical` concern causing verdict `revise`. Matches appearing in
clearly execution-guidance context (e.g. "Generator should run `curl …`") are
downgraded to `severity: info`.

---

## verification-block

The canonical **Verification: block** format is a shared evidence artifact used
wherever a reviewer, peer agent, or checkpoint artifact must back a rejection
or warning with empirical proof. It is referenced by:

- `round-N-planner-response.md` Rejected Changes entries — each warning-level
  rejection attaches a Verification: block.
- `review-loop` rejection entries — the `claude_actions[].verification` field
  (see `log-schema.md` for the `deferred for verification` auto-downgrade
  behavior).
- Any future artifact adopting the Evidence over Authority principle.

**Two valid forms** — every Verification: block MUST be exactly one of:

### Form A — Evidence-based (preferred)

```yaml
Verification:
  command: <exact command run, sanitized — secrets/tokens/hostnames
            replaced with REDACTED or dummy values>
  output: |
    <≤ 20-line snippet of stdout/stderr proving the claim>
  timestamp: <ISO-8601, e.g. 2026-04-17 or 2026-04-17T14:32:10Z>
  contradiction-explanation: <one or two sentences explaining HOW the
                              output contradicts the peer's finding>
```

All four fields (`command`, `output`, `timestamp`, `contradiction-explanation`)
are REQUIRED in Form A.

### Form B — Verification-impossible

```yaml
Verification:
  reason: <why verification could not be performed — e.g. "no network in
           sandbox", "external API requires auth we don't hold",
           "behavior only reproduces under production load">
```

Using Form B is an admission that the rejection rests on authority (spec /
design / convention) without empirical proof. Consumers of the block MUST
auto-downgrade such rejections to `deferred for verification` status:

- In `review-loop`, the finding is NOT counted as `rejected` in `rounds.json`
  (it goes to the `deferred for verification` bucket per
  `log-schema.md#claude_actionsaction`) and is surfaced in `summary.md`'s
  "Deferred for Verification" section when `summary.deferred_for_verification > 0`.
- In spec-review `round-N-planner-response.md`, a warning rejection carrying
  Form B is authority-only: the rejection is recorded as deferred (rather than
  closed) and SHOULD be re-surfaced in the next round by passing the prior
  planner-response.md to the Spec Evaluator (see `planning-protocol.md` step 4's
  "Prior deferred rejections" input). Re-insisted Form B deferrals remain
  autonomous — the Planner should attach Form A evidence in the current round
  if possible, otherwise continue deferring. Unresolved deferrals ride the
  normal `max_spec_rounds`-exhaustion path to user escalation (scenario 1 in
  the exhaustive list); warning-level concerns never trigger a separate user
  escalation.

### Output snippet limit

The `output` field in Form A MUST be ≤ 20 lines by default. When a longer
snippet is genuinely necessary (e.g. a benchmark table, a multi-step repro),
place an HTML comment marker on its own line **immediately before** the block:

```markdown
<!-- evidence-limit: 60 -->
Verification:
  command: ...
  output: |
    ... up to 60 lines ...
```

- `N` MUST be `≤ 100`. Values above 100 are rejected as noise that belongs in
  a separate evidence file rather than inline in the artifact.
- The marker applies only to the immediately following block; the default
  20-line cap resumes afterward.

This convention matches the spec.md Evidence Requirements §Overriding the
line limit — keep the two consistent.

### Timestamp format

ISO-8601, either date-only (`YYYY-MM-DD`) or date-time with timezone
(`YYYY-MM-DDTHH:MM:SSZ` or `±HH:MM` offset). Locale-dependent formats
(`04/17/2026`, `Apr 17 2026`) are rejected.

---

## round-N-spec-review.md (spec-review/)

```yaml
---
task_id: <matches spec>
spec_version: <which version reviewed>
round: <N>
---
```

Sections:

- **Verdict**: approve | revise
- **Scope Assessment**: minimum viable scope analysis, complexity score (files touched, new abstractions), what already exists in codebase
- **Checkpoint Review**: per-checkpoint table — Granularity (OK|TOO_LARGE|TOO_SMALL), Acceptance Criteria (TESTABLE|VAGUE), Dependencies (CORRECT|MISSING), TDD Readiness (YES|NO — required for backend/infra/fullstack, N/A for frontend-only), E2E/Browser Test (YES|NO — required for frontend/fullstack, recommended for backend), UI Evidence Required (YES|NO — YES for frontend/fullstack)
- **Concerns**: numbered, each with severity (critical|warning|info), details, suggested_fix. Critical = blocks execution. Warning = should fix. Info = suggestion.
- **Effort Estimate**: S/M/L per checkpoint
- **Failure Modes**: one realistic production failure scenario per checkpoint

---

## round-N-planner-response.md (spec-review/)

```yaml
---
task_id: <matches spec>
round: <N>
---
```

Sections: Accepted Changes, Rejected Changes, Spec Updated To (version).

Rejected Changes entries for warnings MUST include a Verification: block per §verification-block.

---

## context.md (per checkpoint)

```yaml
---
task_id: <matches spec>
checkpoint: <number>
checkpoint_type: frontend | backend | fullstack | infrastructure
effort_estimate: S | M | L
---
```

Sections: Objective, Prior Progress, Constraints, Files of Interest.

The `checkpoint_type` field determines the Generator's testing strategy (TDD for backend, E2E for frontend) and the Evaluator's Tier 1 checks.

---

## host-conventions-card.md

Planner-side Convention Scout output. This artifact records what the host
repository says about its own verification conventions before a spec is
drafted. It is the single source of truth for Scout, Spec Evaluator, and Retro
consumers.

```yaml
---
task_id: <matches spec>
scout_run_at: <ISO-8601 timestamp>
scout_status: complete | partial | failed
adr_culture_detected: <boolean>
highest_authority_source: P0 | P1 | P2 | P3 | P4 | P5 | P6 | P7 | P8 | P9 | none
host_repo_doc_gap: none | partial | full
docs_vs_ci_drift: none | detected
---
```

Canonical probe priority tiers:

| Tier | Authority surface | Scout probe |
|------|-------------------|-------------|
| P0 | Architectural decision records | Repository decision records such as ADR or decision-log directories. |
| P1 | Repository-specific agent or skill instructions | Local assistant, automation, or skill guidance that governs how work is done in this repo. |
| P2 | Always-on contributor documentation | Root or docs contributor guides that every change author is expected to read. |
| P3 | Dedicated verification documentation | Testing, verification, quality, or review docs with explicit project practice. |
| P4 | Development workflow documentation | Process, release, local setup, or maintenance docs that mention verification expectations. |
| P5 | Human-facing task templates | Issue, pull request, or change templates that ask authors for verification evidence. |
| P6 | Declared project commands | Manifest, task-runner, or command catalog entries that name verification commands. |
| P7 | Repository helper scripts | Checked-in helper scripts whose names or help text describe verification behavior. |
| P8 | Continuous integration reality | CI or automation configuration that runs verification commands. |
| P9 | Inferred executable behavior | Test directories, fixtures, or executable artifacts that imply practice without documenting it. |

Ordering rationale: authority decays while specificity increases. P0-P3 are
the clearest documentation surfaces; P8-P9 can prove what runs but cannot by
themselves explain the repository's intended convention.

Body sections:

- **Per-priority findings**: table with one row per P0-P9 tier. Each row
  records `status` (`FOUND` or `NOT_FOUND`), `path`, and a short sanitized
  `extract`.
- **Contradictions**: any conflict across tiers, especially documented
  guidance that disagrees with CI reality.
- **Gap Classification**: rationale for `host_repo_doc_gap` and
  `docs_vs_ci_drift`.
- **Evidence for Retro**: issue-ready facts Retro can cite without re-scanning
  the host repo.

`host_repo_doc_gap` values:

- `none`: P0-P3 contain substantive convention guidance.
- `partial`: P0-P3 are absent or thin, but P4-P6 contain useful guidance; or
  P0-P3 exist but only point elsewhere.
- `full`: P0-P6 are absent or substantively empty, with signal only from
  P7-P9 or no signal at all.

Minimal filled example:

```markdown
---
task_id: example-task
scout_run_at: 2026-04-24T09:00:00+08:00
scout_status: complete
adr_culture_detected: true
highest_authority_source: P0
host_repo_doc_gap: partial
docs_vs_ci_drift: none
---

## Per-priority findings

| Tier | Status | Path | Extract |
|------|--------|------|---------|
| P0 | FOUND | docs/adr/0001-example.md | "Decisions are recorded as ADRs." |
| P1 | NOT_FOUND | N/A | No repository-specific assistant or skill guidance found. |
| P2 | FOUND | README.md | "Run the verification command before review." |
| P3 | NOT_FOUND | N/A | No dedicated verification guide found. |
| P4 | NOT_FOUND | N/A | No development workflow doc found. |
| P5 | NOT_FOUND | N/A | No change template with verification prompt found. |
| P6 | FOUND | manifest file | Verification command is declared. |
| P7 | NOT_FOUND | N/A | No helper script guidance found. |
| P8 | FOUND | automation config | Verification command runs on change. |
| P9 | FOUND | executable artifacts | Verification artifacts are present. |

## Contradictions

None.

## Gap Classification

`host_repo_doc_gap: partial` because high-authority decision guidance exists,
but dedicated verification documentation is absent. Other valid values are
`none` when P0-P3 are substantive and `full` when P0-P6 are absent or empty.

## Evidence for Retro

- ADR culture detected from P0.
- Dedicated verification guide missing at P3.
- CI drift not detected.
```

---

## output-summary.md (per iteration)

```yaml
---
task_id: <matches spec>
checkpoint: <number>
iteration: <number>
---
```

Sections: What Was Done (+ rationale), Files Modified, Git Commits (SHAs + messages), Rule Conflict Notes (empty if none), Notes for Evaluator.

---

## evaluation.md (per iteration)

```yaml
---
task_id: <matches spec>
checkpoint: <number>
iteration: <number>
verdict: PASS | FAIL | REVIEW
evaluator_agent: harness-evaluator
evaluator_host: claude-code-agent | claude-cli | codex-cli | gemini-cli
evaluator_session_id: <session id from evaluator agent>
---
```

The `verdict` frontmatter is parsed by `$ENGINE pass-checkpoint`. It must match the Verdict section. A checkpoint cannot pass unless the latest iteration's `evaluation.md` has `verdict: PASS`, and the same iteration contains `evaluator-session-id.txt` with a session id that was not used by any prior checkpoint.

### Tier 1: Deterministic Checks (MANDATORY)

Each section has: ran, passed/results, errors/failures, **evidence** (path in evidence/).

- **Magnitude Check**: Read `effort_estimate` from context.md frontmatter. Compute actual insertions (`git diff --stat baseline_sha..HEAD | tail -1`) and file count (`git diff --name-only baseline_sha..HEAD | wc -l`). Compare against thresholds: S=50/3, M=150/8, L=300/12 files. If actual exceeds 3× estimate on either dimension → trigger REVIEW with focus on goal relevance. Evidence: actual vs expected numbers.
- **Tests**: ran, passed (N/total), failed_tests, evidence
- **Test Coverage** (backend/infrastructure/fullstack ONLY, plus any frontend checkpoint whose spec explicitly requires coverage): ran, coverage_percent (project-wide or checkpoint-scoped as specified), threshold (from `.harness/config.json` `coverage_threshold`, default 85, or stricter spec value), passed (coverage ≥ threshold), evidence. **FAIL if required coverage is unmeasured or below threshold** — hard gate. Measured using the project's configured coverage tool. Skip for `Type: frontend` checkpoints only when the spec does not require frontend coverage.
- **TDD Commit Sequence** (backend/infrastructure/fullstack ONLY): verified (Red commit with failing tests exists before Green commit with passing implementation), evidence (commit SHAs showing test-first order). Skip for `Type: frontend` checkpoints.
- **Type Check**: ran, passed, errors, evidence
- **Linter**: ran, passed, warnings, evidence
- **Browser Verification** (frontend/fullstack): ran, console_errors (must be zero), flow_completed, screenshots (MANDATORY — save to evidence/), e2e_test_passed, evidence. **FAIL if no screenshots or E2E evidence for frontend or fullstack checkpoints.**
- **API Verification** (backend/fullstack): ran, endpoints_tested, sample_request_response (MANDATORY — save to evidence/), results, evidence

### Tier 2: LLM Code Review

- patterns_checked, issues_found (severity: critical|warning|info), positive_observations, evidence
- **fault_path_probe** (MANDATORY field): for any code path that reads/parses external input (files, env vars, stdin, arguments into `jq`/`sed`/`awk`/`python`/bash parameter expansion), record either (a) the malformed-input test in the CP's suite and its asserted behaviour, OR (b) the evaluator-led simulation (command + stdout/stderr + exit code) under a `Fault-path probe` heading with evidence in `evidence/`. For CPs with no external input (pure computation, compile-time constants), fill this field with one explicit line: `N/A — pure computation` (or similar). Atomic-writer patterns (`mktemp` + `mv`) must additionally verify the tempfile is on the same filesystem as the target — naked `mktemp` defaults to `$TMPDIR` and produces a non-atomic cross-fs copy+unlink.

### Verdict

- **result**: PASS | FAIL | REVIEW
- **blocking_issues**: (if FAIL)
- **review_items**: (if REVIEW) — structured list, each item:
  - `description`: what the issue is
  - `severity`: low | medium | high | critical
  - `auto_fixable`: true | false (can a Generator fix this mechanically without human guidance?)
  - `requires_human_judgment`: true | false (is this genuinely ambiguous — e.g., design trade-off, spec interpretation, business logic choice?)
  - `fix_hint`: brief instruction for Generator (if auto_fixable=true)
- **auto_resolvable**: true | false (true iff ALL review_items have severity ≤ medium AND auto_fixable=true AND requires_human_judgment=false)
- **feedback_to_generator**: (if FAIL — specific fix instructions)

Rules: PASS = all Tier 1 pass + no critical Tier 2. FAIL = any Tier 1 failure. REVIEW = Tier 1 pass but Tier 2 concerns.

Auto-resolve classification examples:
- Docker config bug (low, auto_fixable=true) → auto_resolvable
- Unused imports / lint warnings (low, auto_fixable=true) → auto_resolvable
- Missing dev dependency (low, auto_fixable=true) → auto_resolvable
- Ambiguous spec interpretation (medium, requires_human_judgment=true) → NOT auto_resolvable
- Potential security concern (high, auto_fixable=false) → NOT auto_resolvable

---

## status.md (per checkpoint)

```yaml
---
checkpoint: <number>
result: PASS | ABORTED
total_iterations: <N>
final_evaluation: <path to final evaluation.md>
evaluator_session_id: <session id from evaluator agent>
---
```

Sections: Summary (one-line), Iteration History (table: Iter/Verdict/Key Issue).

Note: Escalation is an Orchestrator-managed transient decision, not an engine state. When the Orchestrator escalates, it pauses and presents context to the human — no status.md is written for escalated checkpoints.

---

## e2e-report.md

```yaml
---
task_id: <matches spec>
checkpoints_verified: <total>
verdict: PASS | FAIL | REVIEW
---
```

The `verdict` frontmatter is parsed by `$ENGINE pass-e2e`. E2E cannot pass unless the latest `e2e-report.md` has `verdict: PASS`.

Sections: Scope (cross-checkpoint integration), Success Criteria Verification (each criterion: status/evidence/notes), Integration Points Tested, Data-Flow Audit (table: Flow | Producer CP → Consumer CP | Boundary type | Shape match? | Staleness risk?), Verdict (PASS|FAIL|REVIEW + blocking_issues/review_items).

The Data-Flow Audit section is mandatory. The E2E Evaluator independently reads all checkpoint code, identifies concrete values that cross checkpoint boundaries (props, cache keys, API shapes, store state), and traces each producer→consumer path. Use "Depends on" fields from spec to prioritize flows. Any shape mismatch or unhandled staleness → severity=high review_item.

---

## verification-report.md (full-verify/iter-N/)

```yaml
---
task_id: <matches spec>
iteration: <N>
verdict: PASS | PASS_WITH_WARNINGS | FAIL
hard_failures: <count>
soft_warnings: <count>
coverage_percent: <number or "N/A">
---
```

The `coverage_percent` field is **parsed by the engine** in `pass-full-verify`. For backend/infra/fullstack tasks, the engine will PHASE_BLOCK if this value is below the configured threshold (default 85%). Set to `N/A` for frontend-only tasks where coverage is not measured.

Sections:
- **Hard Failures**: list of failed checks with command, exit code, error output
- **Soft Warnings**: list of non-blocking issues (e.g., "README.md missing test instructions"). Note: required test coverage below the configured/spec threshold on backend/infrastructure/fullstack checkpoints is a **hard failure**, not a soft warning. Frontend-only checkpoints are exempt from coverage thresholds unless the spec explicitly requires coverage.
- **Checks Executed**: table with columns Check | Command | Result | Duration

Verdict semantics: `PASS` = zero hard failures (soft warnings allowed). `PASS_WITH_WARNINGS` = zero hard failures with soft warnings explicitly noted. `FAIL` = one or more hard failures.

---

## discovery.md (full-verify/)

```yaml
---
task_id: <matches spec>
project_type: node | python | go | make | unknown
---
```

Sections:
- **Detected Check Commands**: table with columns Name | Command | Source (e.g., "package.json scripts.test")
- **Test Framework**: detected test framework name or "unknown"
- **Coverage Tool**: detected tool (c8, istanbul, coverage.py, etc.) or "none detected"

---

## git-state.json

```json
{
  "task_id": "...",
  "task_start_sha": "...",
  "phase": "init | checkpoints | e2e | review-loop | full-verify | pr | retro | done",
  "checkpoints": {
    "01": {
      "baseline_sha": "...",
      "iterations": { "1": { "end_sha": "..." } },
      "final_sha": "...",
      "aborted": false
    }
  },
  "e2e_baseline_sha": "...",
  "e2e_final_sha": "...",
  "review_loop_status": "COMPLETE | SKIPPED | (empty)",
  "review_loop_session_id": "...",
  "review_loop_summary_file": ".review-loop/latest/summary.md",
  "review_loop_rounds_file": ".review-loop/latest/rounds.json",
  "full_verify_baseline_sha": "...",
  "full_verify_final_sha": "...",
  "full_verify_status": "COMPLETE | SKIPPED | (empty)",
  "pr_url": "https://github.com/..."
}
```

**Phase field (v0.4.0):** The engine enforces a linear phase progression: `init → checkpoints → e2e → review-loop → full-verify → pr → retro → done`. Downstream commands check phase before executing. If phase is wrong, the engine returns `PHASE_BLOCKED`.

**Phase commands:**
- `pass-checkpoint` — requires latest iteration `output-summary.md`, latest iteration `evaluation.md`, `evaluation.md` verdict PASS, and fresh `evaluator-session-id.txt`; then records final SHA.
- `pass-e2e` — requires latest `e2e/iter-N/e2e-report.md` verdict PASS; then records final SHA and sets phase to `e2e`.
- `pass-review-loop` — verifies `.review-loop/latest/summary.md` + `rounds.json` exist, `session.status` is `consensus` or `read_only_complete`, and `session.total_rounds >= 1`; then records the session id and sets phase to `review-loop`
- `skip-review-loop` — only allowed when `cross_model_review=false` in config, sets phase to `review-loop`
- `begin-full-verify` — requires phase `review-loop`, sets phase to `full-verify`, creates `full-verify/` directory
- `pass-full-verify` — requires `full-verify/iter-N/verification-report.md` with verdict PASS or PASS_WITH_WARNINGS, rejects stale artifacts, records final SHA
- `skip-full-verify` — only allowed when `skip_full_verify=true` in config, sets phase to `full-verify`
- `pass-pr --pr-url <url>` — records PR URL, sets phase to `pr`
- `complete` — sets phase to `done`

When `aborted` is `true`, the checkpoint is terminal — skipped by status, validation, and abort auto-detection.

---

## retro-input.md (Orchestrator assembles)

```yaml
---
task_id: <matches spec>
task_title: <from spec>
---
```

Sections: Task Metrics (checkpoints_total, passed_first_try, total_iterations, commits, reverts, avg_iterations), Per-Checkpoint Summary (table), All Rule Conflict Notes, E2E Result, Git Activity.

---

## issue-routing

Every `Issue-ready: true` retro item MUST include this markdown body field:

```markdown
- **target_repo**: harness | host | both
```

Canonical harness target shell default:

```bash
HARNESS_TARGET_REPO="${HARNESS_TARGET_REPO:-stone16/harness-engineering-skills}"
```

Maintain this `owner/repo` literal in sync with this repository's public
`origin` remote, normalized by removing any protocol and optional `.git` suffix.
Verify it with
`scripts/check-harness-target-repo.sh` after repository moves or release prep.

Classification:

- `harness`: skill defects, engine changes, and protocol changes owned by
  the harness-engineering-skills maintainers.
- `host`: project tech-stack rules, project CLAUDE.md guidance, and project
  code cleanup owned by the current repository.
- `both`: findings that require both a harness-side fix and a host-repo rule
  or cleanup item, plus genuinely ambiguous ownership where filing both sides
  preserves the feedback loop.

Precedence: the explicit `target_repo` field is required. Missing or invalid
values are filing errors to record in Filed Issues, not defaults to `host`.

For `target_repo: both`, file one issue in `HARNESS_TARGET_REPO` and one in
the host repo, then update both bodies with `Cross-filed: <other_url>`. The
retro's Filed Issues record uses one line for the pair:

```markdown
- Proposal N (both): <harness-url> | <host-url>
```

Filed Issues record formats:

- `- Proposal N (host): <host-url>`
- `- Proposal N (harness): <harness-url>`
- `- Proposal N (both): <harness-url> | <host-url>`
- `- Proposal N (skipped): gh CLI unavailable`
- `- Proposal N (skipped, host repo unresolved): <title>`
- `- Proposal N (skipped, invalid target_repo='<raw>'): <title>`
- `- Proposal N (skipped, <host|harness> create failed): <title>`
- `- Proposal N (both, cross-link skipped, mktemp failed): <harness-url> | <host-url>`
- `- Proposal N (both, partial create): <harness-url|no-harness-url> | <host-url|no-host-url>`
- `- Proposal N (both, partial edit harness=<ok|failed> host=<ok|failed>): <harness-url> | <host-url>`

Records may include a `label not applied` or `labels harness=<true|false>
host=<true|false>` note inside the parenthesized status when issue creation
succeeds but the best-effort `harness-retro` label is unavailable.

---

## retro.md (PERSISTENT, in .harness/retro/)

```yaml
---
task_id: <matches spec>
task_title: <from spec>
date: <ISO date>
checkpoints_total: <N>
checkpoints_passed_first_try: <N>
total_eval_iterations: <N>
total_commits: <N>
reverts: <N>
avg_iterations_per_checkpoint: <float>
---
```

Sections: Observations (Error Patterns with [category: tag], Rule Conflict Observations, What Worked Well), Recommendations (Upgrade to Rule with drafted CLAUDE.md text, Upgrade to Principle, Rule Conflict Resolution, Skill Defect Flags).

Every `Issue-ready: true` recommendation or defect carries the required
`target_repo` field from §issue-routing.

---

## retro/index.md (PERSISTENT)

Sections: Error Pattern Frequency (table: Category/Total/Last 10/Trend/Status), Pending Rule Proposals, Pending Principle Proposals, Rule Lifecycle Tracker, Skill Defect Log, Filed Issues.

Filed Issues rows may contain one URL or, for `target_repo: both`, both URLs
on one line in the format defined by §issue-routing.
