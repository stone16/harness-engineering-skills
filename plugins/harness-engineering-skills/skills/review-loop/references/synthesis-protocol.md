# Review Loop — Synthesis Protocol

How the host agent evaluates peer findings, modifies code, and drives convergence.

---

## 1. Finding Evaluation Criteria

For each peer finding, the host agent evaluates and decides **ACCEPT** or **REJECT**.

### ACCEPT when:

- Finding identifies a genuine bug, logic error, or edge case
- Finding highlights a real security vulnerability
- Finding points to a measurable performance issue
- Finding aligns with project standards (CLAUDE.md, linter rules, conventions)
- Fix is actionable and within the review scope

### REJECT when:

- False positive — the code is actually correct (explain why)
- Stylistic preference with no functional impact and no project convention requiring it
- Conflicts with explicit project conventions in CLAUDE.md
- Fix would introduce more complexity than the issue it solves
- Issue is outside the review scope (pre-existing, unrelated files)
- Suggestion duplicates existing functionality

### Rejection Requirements

Every rejection MUST include a Verification: block per protocol-quick-ref.md §verification-block. Authority-only rejections (references to spec/design/conventions without verification output) are auto-downgraded to "deferred for verification".

Supporting expectations around that block:

1. **Specific reasoning** — the `contradiction-explanation` field must say "this is a false positive because X", not "I disagree".
2. **Evidence** — the `command` and `output` fields back the reasoning with empirical proof; a reference to code, docs, or conventions ALONE is Form B (authority-only) and triggers the auto-downgrade.
3. **Openness** — acknowledge if the peer has a point but explain the trade-off; a contradictory peer argument does not excuse omitting the Verification: block.

When verification is genuinely impossible (no network, no access, load-dependent behavior), use Form B with a `reason` field. The finding is NOT recorded as `rejected` in rounds.json — it is recorded as `deferred for verification` (see [log-schema.md](log-schema.md#claude_actionsaction)) and surfaced in summary.md's "Deferred for Verification" section.

---

## 2. Code Modification Rules

### Before modifying code:

1. Create a checkpoint commit: `git commit -m "review-loop: checkpoint before round N"`
2. This enables rollback via `git reset --soft HEAD~1` if changes are problematic

### When modifying code:

- **Scope**: Only modify files within the review target set (the original local file list / PR / commit scope)
- **Minimal changes**: Fix the specific issue, don't refactor surrounding code
- **Style preservation**: Match existing code style (indentation, naming, patterns)
- **No new features**: Don't add functionality beyond what the finding requires
- **Test awareness**: If fixing a bug, ensure existing tests still pass

### After modifying code:

- Record exactly which files and lines were changed in `claude_actions.code_changes`
  - `claude_actions` is the historical schema field name even when Codex hosts the loop
- The next peer round should receive the updated local workspace plus the list of files touched this round

---

## 3. Convergence Protocol

### Consensus is reached when ALL of these are true:

- Peer returns **no new findings** in the latest round
- Peer responds with `CONSENSUS:` or has no remaining `INSIST:` items
- All previously accepted findings have been implemented

### Per-finding resolution flow:

```
Finding → Host ACCEPT → Code changed → Peer re-reviews
  └── Peer satisfied → RESOLVED
  └── Peer has concerns about fix → New finding in next round

Finding → Host REJECT (with reasoning) → Sent to peer
  └── Peer: ACCEPTED_REJECTION → RESOLVED
  └── Peer: INSIST (round 1) → Host re-evaluates
       └── Host changes mind → ACCEPT → Code changed
       └── Host still disagrees → Send stronger reasoning
            └── Peer: ACCEPTED_REJECTION → RESOLVED
            └── Peer: INSIST (round 2) → ESCALATED
```

### Limits:

| Limit | Default | Purpose |
|-------|---------|---------|
| Max rounds total | 5 | Prevents infinite loops |
| Max back-and-forth per finding | 2 | Prevents endless debate on one issue |
| Peer timeout per round | 600s | Prevents hung CLI processes |

### When max rounds reached:

- Stop the loop
- Mark unresolved findings as `escalated` in summary
- Generate report with status `max_rounds`
- Clearly list what remains unresolved for human review

---

## 4. Escalation Criteria

A finding is marked **ESCALATED** (needs human decision) when:

- Debated for 2+ rounds without resolution (STALEMATE)
- Involves an architectural decision beyond a code-level fix
- Security concern where the host agent cannot definitively determine correctness
- Peer and host agent have fundamentally different interpretations of requirements

### Escalation format in summary.md:

```markdown
## Escalated Items (Needs Human Decision)

### Finding f3: Database connection pool sizing
- **Peer says**: Pool size of 10 is too low for expected load
- **Host says**: Pool size matches current infrastructure limits
- **Rounds debated**: 2
- **Recommendation**: Review with infrastructure team before changing
```

---

## 5. Round Execution Checklist

The host agent follows this for each round:

- [ ] Read peer output from `peer-output/round-N-raw.txt`
- [ ] Parse findings (look for `FINDING:`, `CONSENSUS:`, `ACCEPTED_REJECTION:`, `INSIST:`)
- [ ] For each finding: evaluate → ACCEPT or REJECT
- [ ] Implement code changes for all ACCEPTED findings
- [ ] Create checkpoint commit
- [ ] Update `rounds.json` with this round's data
- [ ] Check convergence:
  - All resolved? → Phase 3 (Final Report)
  - Unresolved items? → Build re-review prompt → Next round
  - Round > MAX_ROUNDS? → Phase 3 with `max_rounds` status

---

## 6. Harness Full-Verify Coupling

When `review-loop` is running inside a harness task that also has a
full-verify gate, the host agent keeps the review-loop report aligned with the
harness protocol:

- `discovery-gate mirror`: run every gate named by the current task's
  `full-verify/discovery.md` for the touched surface, or record that no
  touched-surface gate applies.
- `post-fix integration audit`: if `review_loop_status: COMPLETE` and the
  loop modified files, include `Review-loop Post-fix Integration Audit` in
  `verification-report.md` with per-finding re-proof commands.
- `async lifecycle heuristic`: if the diff constructs `asyncio.Queue`,
  `asyncio.Lock`, `asyncio.Event`, or background tasks at import or module
  scope, include focused project lifespan/startup tests in the round evidence.
