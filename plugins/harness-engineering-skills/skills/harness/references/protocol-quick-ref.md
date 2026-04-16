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
- **Test Framework**: detected framework name (jest, vitest, pytest, etc.) or "unknown"
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
- `pass-review-loop` — verifies `.review-loop/latest/summary.md` + `rounds.json` exist, `session.status` is `consensus`, and `session.total_rounds >= 1`; then records the session id and sets phase to `review-loop`
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

---

## retro/index.md (PERSISTENT)

Sections: Error Pattern Frequency (table: Category/Total/Last 10/Trend/Status), Pending Rule Proposals, Pending Principle Proposals, Rule Lifecycle Tracker, Skill Defect Log.
