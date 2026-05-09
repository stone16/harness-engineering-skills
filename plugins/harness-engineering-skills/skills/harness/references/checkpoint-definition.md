# Checkpoint Definition Spec

Defines what a checkpoint is, how the Planner should write them, and how they behave during execution.

---

## What Is a Checkpoint

A checkpoint is the smallest execution unit of the Harness pipeline. Each checkpoint:

- Is implemented by a fresh Generator agent independently
- Is verified by a fresh Evaluator agent independently
- Produces testable, verifiable results
- Uses sequential flat numbering (01, 02, 03...)

---

## Numbering Rules

- **Format**: two-digit, zero-padded (01, 02, ..., 99)
- **Strictly incrementing**, no gaps
- **No letter suffixes** (~~03A~~, ~~03B~~)
- **No nested levels** (~~03.1~~, ~~03.2~~)

---

## Granularity Standards

A checkpoint should be completable by a Generator in **one pass** and verifiable by an Evaluator with clear evidence.

### Three Dimensions

| Dimension | Suitable | Too Large | Too Small |
|-----------|----------|-----------|-----------|
| Change volume (insertions) | 50–200 lines | >300 lines | <10 lines |
| File count | 1–8 files | >12 files | — |
| Verification complexity | 1–3 Tier 1 checks | Multiple independent features | No verifiable output |

These are guideline ranges, not hard constraints. A checkpoint modifying 2 files with complex algorithms may be harder than a mechanical checkpoint modifying 10 files. The Planner should judge holistically.

### Split Signals (too large — should split)

- Objective contains "and" — "create hook **and** apply to all screens" → split into two
- Files span multiple concerns — hook implementation + screen modification + style adjustment → split by concern
- Spec Evaluator marks `Granularity: TOO_LARGE`

### Merge Signals (too small — should merge)

- Change does not produce independently verifiable results — "create an empty file" is not a valid checkpoint
- Two checkpoints modify the same function in the same file → merge
- Spec Evaluator marks `Granularity: TOO_SMALL`

---

## Scope and Objective Constraint

The `Scope` field is the checkpoint's **objective statement, not a file list**.

Generator's scope constraint binds to Scope. The judgment rule:

> **If removing a modification does not affect achievement of the Scope objective → that modification should not exist.**

This means:

- Generator **may** modify files outside "Files of interest" if necessary to achieve the objective
- Generator **may** create new files if necessary to achieve the objective
- Generator **must not** make improvements, refactoring, or optimizations unrelated to the objective — document these in output-summary.md under "Recommended Follow-up"

### Infrastructure checkpoints editing protocol/reference documents

When a checkpoint's Scope includes ≥2 harness protocol files, OR edits any
file with known sibling cross-references (e.g., `planning-protocol.md` ↔
`codex-mode.md` ↔ `protocol-quick-ref.md`, or similar reference-document
clusters), the Generator MUST perform a sibling-scan after completing the
primary edit:

1. Grep sibling protocol files for the phrase/rule just edited.
2. If the sibling contains the same concept, re-read the sibling to verify
   it does not contradict the primary edit.
3. If contradiction exists, either (a) propose extending Scope via
   output-summary.md's Scope Expansion Request, OR (b) document the residual
   contradiction in Rule Conflict Notes so E2E Evaluator surfaces it.

This is particularly important for escalation rules, enum values, carrier
field names, and exact-sentence contracts — the E2E Data-Flow Audit tracks
named producer→consumer contracts, not unnamed sibling contradictions, so
those divergences would otherwise slip through to review-loop or retro.

---

## Effort Estimate

Measured in **insertions only** (lines added in `git diff`, the `+` lines). Does not include deletions.

| Estimate | Expected Insertions | Expected Files | Magnitude Warning (3×) |
|----------|--------------------:|---------------:|----------------------:|
| S | ~50 lines | 1–3 | >150 lines or >9 files |
| M | ~150 lines | 4–8 | >450 lines or >24 files |
| L | ~300 lines | 8–12 | >900 lines or >36 files |

When actual changes exceed the 3× threshold, the Evaluator triggers REVIEW (not FAIL) with focus on whether modifications are goal-relevant.

---

## Acceptance Criteria Quality Standards

Each criterion must be verifiable through concrete evidence.

### Good Criteria (specific, testable)

```
- [ ] useScreenPadding() returns { paddingHorizontal: number }
- [ ] post-detail.tsx applies padding via inline style
- [ ] tsc --noEmit passes with zero errors
- [ ] existing project tests pass (project test command)
```

### Bad Criteria (vague, untestable)

```
- [ ] Code is clean and well-structured        ← subjective
- [ ] Padding works correctly                   ← "correctly" undefined
- [ ] Performance is acceptable                 ← no metric
- [ ] All edge cases are handled                ← which edge cases?
```

### Testing Criteria (Mandatory, by Type)

Every checkpoint MUST include at least one testability criterion. Strategy differs by type:

**`Type: backend` / `Type: infrastructure`** — TDD + coverage:
```
- [ ] Tests pass with coverage ≥ `.harness/config.json` `coverage_threshold` (default 85%) or stricter spec value
- [ ] Integration test covers [API endpoint / data path]
- [ ] Red commit (failing tests) exists before Green commit (passing implementation)
```

**`Type: frontend`** — E2E interaction + visual proof (unit coverage NOT required):
```
- [ ] E2E test verifies [click flow / navigation / form submission]
- [ ] Screenshot: [specific screen/state] renders correctly
- [ ] Zero console errors in browser
```

**`Type: fullstack`** — both strategies applied to respective portions:
```
- [ ] Backend: tests pass with coverage ≥ `.harness/config.json` `coverage_threshold` (default 85%) or stricter spec value
- [ ] Frontend: E2E test verifies [user flow]
- [ ] Frontend: screenshot of [key state] renders correctly
```

### Quantity Guidance

- **3–6 criteria per checkpoint** (at least 1 must be a test criterion)
- Fewer than 3 → may miss verification points
- More than 6 → checkpoint may be too large, consider splitting

---

## Dependency Rules

- Checkpoints in the same `parallel_group` execute concurrently within a cohort; cohorts execute sequentially.
- A checkpoint may assume that all PASS members of every prior cohort are complete.
- Cohort order is determined by the lowest checkpoint number in each cohort.
- `Depends on` declares data dependencies (e.g., "CP03 uses the hook created in CP01") — used by E2E agent for data-flow tracing.
- The engine rejects cohorts whose members declare `Depends on` edges among themselves.
- If two checkpoints are completely independent, they may share a `parallel_group`; otherwise numbering still increments and absent `parallel_group` fields preserve serial execution.

---

## Wiring Checkpoint — Multi-Layer Integration Pattern

When a task has **≥5 checkpoints spanning ≥2 layers** (e.g., primitives in a
lib layer + services in an app layer + hooks in a UI layer), the Planner
MUST add a dedicated **Wiring Checkpoint** whose sole job is to verify that
every primitive introduced by earlier checkpoints is invoked by its real
production caller with the correct arguments, without mocking the seam
under test.

Module-boundary decomposition tends to leave "someone-else-will-wire-this-
later" gaps — each CP ships a self-consistent primitive, but no CP owns
end-to-end caller threading. Those gaps are hard to catch with isolated
per-checkpoint validation and tend to survive internal full-verify because
the integration smoke path still mocks the seams where the bugs live.

### Wiring Checkpoint rules

1. **No new primitives.** The Wiring CP only threads and verifies existing
   ones. If the Wiring CP needs a new primitive, it belongs in a regular
   checkpoint first.
2. **Real-caller tests.** For each new primitive introduced by earlier
   checkpoints, add a test that exercises its **real production caller**
   and asserts the call shape and arguments (not a mock of the caller).
3. **Caller-to-primitive verification matrix.** Include a table in the
   Wiring CP's output-summary.md mapping each primitive to its production
   caller and the test file that exercises that call.
4. **Explicit mock boundaries.** List which layers are mocked in each test
   and which are real. A top-level smoke test that mocks everything below
   the entry point is **not** a wiring test for seams above the mocked
   layer — flag those explicitly.

### When to add a Wiring Checkpoint

| Task shape | Wiring CP needed? |
|---|---|
| ≤4 checkpoints, single layer | No — per-CP integration tests suffice |
| ≥5 checkpoints, single layer | Consider one if seams cross ≥2 concerns (e.g. DB + HTTP) |
| ≥5 checkpoints, ≥2 layers | **Yes — add a dedicated Wiring CP as the last pre-E2E checkpoint** |
| Any shape with a caller-threading gap pattern in retro history | Yes |

The Wiring CP is typically the last checkpoint before E2E. Failed wiring is
much cheaper to diagnose at this stage than at E2E where multiple layers
are in play simultaneously.

---

## Checkpoint Format (in spec.md)

```markdown
### Checkpoint 03: Apply padding hook to index and post-detail screens

- **Scope**: Import useScreenPadding and apply to 2 community screens
- **Depends on**: CP01 (hook creation)
- Type: frontend
- **Acceptance criteria**:
  - [ ] index.tsx calls useScreenPadding() and applies returned padding
  - [ ] post-detail.tsx calls useScreenPadding() and applies returned padding
  - [ ] E2E: navigate to community index → padding visually applied
  - [ ] Screenshot: community index and post-detail screens with padding applied
  - [ ] Zero console errors in browser during navigation
  - [ ] No TypeScript errors introduced (tsc --noEmit)
- **Files of interest**: src/screens/community/index.tsx, src/screens/community/post-detail.tsx
- **Effort estimate**: S
```

### Field Reference

| Field | Required | Purpose |
|-------|:--------:|---------|
| Scope | Yes | Objective statement — Generator's scope constraint binds here |
| Depends on | No | Upstream data dependency — E2E agent uses for data-flow tracing |
| Type | Yes | Determines which Tier 1 checks the Evaluator runs (frontend \| backend \| fullstack \| infrastructure) |
| parallel_group | No | Cohort letter (single uppercase A-Z); checkpoints with the same letter are dispatched concurrently. Absent = single-member cohort (serial). |
| Acceptance criteria | Yes | Evaluator's verification checklist — must be testable |
| Files of interest | No | Reference information — Generator may go beyond this list |
| Effort estimate | Yes | Baseline for magnitude warning (S/M/L) |

---

## Checkpoint Mutation During Execution

### Rules by Checkpoint State

| State | Allowed Actions |
|-------|----------------|
| **PASS** | Immutable. Code, evaluation results, and status are final. |
| **In progress** | Can abort (`$ENGINE abort`), rolls back to baseline_sha. |
| **Not started** | Can modify scope, acceptance criteria, effort estimate, or delete entirely. |

### Split After Failure

When a checkpoint FAILs after max retries and human decides to split:

1. Abort the failing checkpoint
2. Edit spec.md — split the original into new checkpoints with new numbers
3. Subsequent checkpoints renumber upward (CP05 → CP06, etc.)
4. `harness continue` resumes from the first new checkpoint

### Constraints

- **Never** renumber PASS checkpoints
- **Never** modify PASS checkpoint scope or criteria
- **Never** insert new checkpoints before PASS checkpoints in the sequence

---

## Planner Responsibilities

The Planner in Session 1 is responsible for:

1. **Splitting** — break the task into appropriately granular checkpoints, each with a clear objective
2. **Ordering** — arrange by dependency and implementation logic
3. **Labeling** — mark each checkpoint with Type and Effort estimate
4. **Writing criteria** — produce testable acceptance criteria (Spec Evaluator checks TESTABLE|VAGUE)

### Host Conventions Card Use

When `.harness/<task-id>/host-conventions-card.md` is available, the Planner
should cite the Host Conventions Card in the spec's Technical Approach and use
its evidence when writing acceptance criteria. Criteria should reference the
repo convention source when the Card found one, rather than implying a
convention without attribution.

If Scout surfaces ambiguity, such as `host_repo_doc_gap: partial|full`, or the
Card is unavailable because `scout_status != complete`, the Planner should
funnel that ambiguity into the spec's Open Questions instead of encoding it as
a vague checkpoint criterion.

The Planner does **not**:

- Specify implementation details (Generator's job)
- Lock down file lists (Files of interest is reference only)
- Use sub-numbering (flat 01, 02, 03... only)
- Determine implementation approach (Generator decides HOW)
