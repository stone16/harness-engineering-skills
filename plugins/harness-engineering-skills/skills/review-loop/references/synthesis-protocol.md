# Review Loop — Synthesis Protocol

How Claude Code evaluates peer findings, modifies code, and drives convergence.

---

## 1. Finding Evaluation Criteria

For each peer finding, Claude evaluates and decides **ACCEPT** or **REJECT**.

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

Every rejection MUST include:
1. **Specific reasoning** — not "I disagree" but "this is a false positive because X"
2. **Evidence** — reference to code, docs, or conventions that support the rejection
3. **Openness** — acknowledge if the peer has a point but explain the trade-off

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
- The next peer round should receive the updated local workspace plus the list of files touched this round

---

## 3. Convergence Protocol

### Consensus is reached when ALL of these are true:

- Peer returns **no new findings** in the latest round
- Peer responds with `CONSENSUS:` or has no remaining `INSIST:` items
- All previously accepted findings have been implemented

### Per-finding resolution flow:

```
Finding → Claude ACCEPT → Code changed → Peer re-reviews
  └── Peer satisfied → RESOLVED
  └── Peer has concerns about fix → New finding in next round

Finding → Claude REJECT (with reasoning) → Sent to peer
  └── Peer: ACCEPTED_REJECTION → RESOLVED
  └── Peer: INSIST (round 1) → Claude re-evaluates
       └── Claude changes mind → ACCEPT → Code changed
       └── Claude still disagrees → Send stronger reasoning
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
- Security concern where Claude cannot definitively determine correctness
- Peer and Claude have fundamentally different interpretations of requirements

### Escalation format in summary.md:

```markdown
## Escalated Items (Needs Human Decision)

### Finding f3: Database connection pool sizing
- **Peer says**: Pool size of 10 is too low for expected load
- **Claude says**: Pool size matches current infrastructure limits
- **Rounds debated**: 2
- **Recommendation**: Review with infrastructure team before changing
```

---

## 5. Round Execution Checklist

Claude follows this for each round:

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
