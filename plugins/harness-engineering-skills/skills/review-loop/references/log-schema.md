# Review Loop — JSON Log Schema

This defines the structure of `rounds.json`, the structured log file created in each review session.
The field name `claude_actions` is retained for backward compatibility even when Codex is the host agent.

## File Location

```
.review-loop/<session-id>/rounds.json
```

## Schema

```json
{
  "session": {
    "id": "<YYYY-MM-DD>-<HHMMSS>-<scope-description>",
    "scope": "local-diff | pr-<number> | commit-<sha>",
    "scope_detail": "human-readable summary, e.g. '3 files changed, 42 insertions'",
    "peer": "codex | claude | gemini",
    "started_at": "ISO 8601 timestamp",
    "completed_at": "ISO 8601 timestamp (null if in_progress)",
    "status": "in_progress | consensus | max_rounds | aborted",
    "total_rounds": 0
  },
  "rounds": [
    {
      "round": 1,
      "timestamp": "ISO 8601 timestamp",
      "peer_findings": [
        {
          "id": "f<N>",
          "file": "exact/file/path.ts",
          "line": 42,
          "severity": "critical | major | minor | suggestion",
          "title": "One-line summary",
          "description": "1-3 sentences explaining the issue",
          "peer_suggestion": "Concrete fix or improvement"
        }
      ],
      "claude_actions": [
        {
          "finding_id": "f<N>",
          "action": "accept | reject | reported | deferred for verification",
          "reasoning": "Why Claude accepted or rejected this finding (empty for reported)",
          "verification": "Inline Verification: block (Form A or Form B per protocol-quick-ref.md §verification-block) — REQUIRED for action=reject; OPTIONAL for accept/reported; Form B presence triggers auto-downgrade from reject to 'deferred for verification'",
          "code_changes": ["file:line-range that was modified (if accepted, empty for reported)"]
        }
      ]
    }
  ],
  "summary": {
    "total_findings": 0,
    "accepted": 0,
    "rejected_then_resolved": 0,
    "escalated": 0,
    "reported": 0,
    "deferred_for_verification": 0,
    "files_modified": ["list of files that were changed"]
  }
}
```

## Field Details

### session.status

| Value | Meaning |
|-------|---------|
| `in_progress` | Review loop is still running |
| `consensus` | Both agents agree — review complete |
| `max_rounds` | Hit MAX_ROUNDS limit, some items may be unresolved |
| `aborted` | Review was cancelled (timeout, error, user interrupt) |
| `read_only_complete` | Read-only mode — findings reported, no code changes made |

### peer_findings[].severity

| Level | Meaning |
|-------|---------|
| `critical` | Must fix — security vulnerability, data loss risk |
| `major` | Should fix — bugs, logic errors, significant issues |
| `minor` | Nice to fix — code quality, minor improvements |
| `suggestion` | Optional — style, alternative approaches |

### claude_actions[].action

| Action | Meaning |
|--------|---------|
| `accept` | Host agent agrees and will implement the fix |
| `reject` | Host agent disagrees, provides reasoning to peer, AND attaches a `Verification:` block in `claude_actions[].verification` per [protocol-quick-ref.md §verification-block](../../harness/references/protocol-quick-ref.md#verification-block). Form B (verification-impossible) triggers auto-downgrade to `deferred for verification` — see [synthesis-protocol.md §Rejection Requirements](./synthesis-protocol.md). |
| `reported` | Finding recorded without action (read-only mode) |
| `deferred for verification` | Finding is not blocking but remains unresolved; peer is NOT required to re-evaluate; surfaced in summary.md's Deferred for Verification section. Produced by auto-downgrade of an authority-only rejection per [synthesis-protocol.md §Rejection Requirements](../references/synthesis-protocol.md) (Form B Verification: block — see [protocol-quick-ref.md §verification-block](../../harness/references/protocol-quick-ref.md#verification-block)). |

## Example

```json
{
  "session": {
    "id": "2026-03-10-143025-local-diff",
    "scope": "local-diff",
    "scope_detail": "3 files changed, 42 insertions, 10 deletions",
    "peer": "codex",
    "started_at": "2026-03-10T14:30:25Z",
    "completed_at": "2026-03-10T14:35:12Z",
    "status": "consensus",
    "total_rounds": 2
  },
  "rounds": [
    {
      "round": 1,
      "timestamp": "2026-03-10T14:31:00Z",
      "peer_findings": [
        {
          "id": "f1",
          "file": "src/auth.ts",
          "line": 42,
          "severity": "major",
          "title": "SQL injection in user lookup",
          "description": "User input concatenated directly into SQL query without parameterization.",
          "peer_suggestion": "Use parameterized query: db.query('SELECT * FROM users WHERE id = $1', [userId])"
        }
      ],
      "claude_actions": [
        {
          "finding_id": "f1",
          "action": "accept",
          "reasoning": "Valid concern — parameterized queries prevent SQL injection",
          "code_changes": ["src/auth.ts:42-45"]
        }
      ]
    },
    {
      "round": 2,
      "timestamp": "2026-03-10T14:34:00Z",
      "peer_findings": [],
      "claude_actions": []
    }
  ],
  "summary": {
    "total_findings": 1,
    "accepted": 1,
    "rejected_then_resolved": 0,
    "escalated": 0,
    "files_modified": ["src/auth.ts"]
  }
}
```
