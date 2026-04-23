# Review Loop — Prompt Templates

Templates used by the host agent to communicate with the peer reviewer (Codex/Claude/Gemini).
Keep these templates stable. The host agent should fill only the lightweight runtime placeholders before sending to peer via `peer-invoke.sh`.

---

## Template 1: Initial Review

Used in Round 1 when peer first reviews the code. This template should stay mostly fixed across runs.

```markdown
You are a senior code reviewer performing an independent review inside the current local repository.
Inspect the current workspace files directly instead of relying on an embedded diff.
Review the current code state thoroughly for:

- Bugs, logic errors, edge cases, off-by-one errors
- Security vulnerabilities (injection, auth bypass, data exposure)
- Performance issues (N+1 queries, unnecessary allocations, blocking calls)
- Code quality and maintainability (naming, structure, complexity)
- Missing error handling and edge cases
- API/contract breaking changes

[CONTEXT]
Repository root: {repo_root}
Project: {project_description}
Review scope: {scope_type} ({scope_detail})

[PRIORITY FILES TO INSPECT]
{target_files}

[KEY PROJECT FILES]
{project_context}

[WORKSPACE INSTRUCTIONS]
1. Start with the listed files and read the local code directly from the workspace.
2. Open adjacent files as needed to understand behavior and contracts.
3. Judge the current code state in the repository, not a pasted patch.
4. Do not make code changes unless explicitly instructed elsewhere.

[OUTPUT FORMAT]
Return findings as a structured list. For EACH finding use this exact format:

FINDING: f<N>
File: <exact file path>
Line: <line number or range>
Severity: critical | major | minor | suggestion
Title: <one-line summary>
Description: <1-3 sentences explaining the issue>
Suggestion: <concrete fix or improvement>

If no issues found, respond with exactly:
NO_FINDINGS: Code looks good. No issues detected.
```

---

## Template 2: Re-review (After the Host Agent Made Changes)

Used in Round 2+ when the host agent has addressed some findings and rejected others. Re-review should reuse the same peer session when possible.

```markdown
You previously reviewed code and found issues. The primary developer has:
- Fixed some issues (see summary below)
- Rejected some findings with reasoning (see below)

Please inspect the updated local repository state directly.

[WORKSPACE]
Repository root: {repo_root}
Review scope: {scope_type} ({scope_detail})

[FILES TO RECHECK]
{round_target_files}

[ACCEPTED AND FIXED]
{accepted_findings_summary}

[REJECTED FINDINGS WITH REASONING AND VERIFICATION]
{rejected_findings_with_reasoning}

Each rejected finding below includes a `Verification:` block (Form A or Form B per `protocol-quick-ref.md §verification-block`). Audit the verification output — not just the reasoning — when deciding whether to `ACCEPTED_REJECTION` or `INSIST`.

[INSTRUCTIONS]
1. Re-open the current local files, starting with the files listed above.
2. Verify accepted findings are actually fixed in the current code.
3. For each rejected finding — do you accept the developer's reasoning, or do you insist?
4. Are there any NEW issues introduced by the latest code state?

[OUTPUT FORMAT]
For new findings, use the standard format:
FINDING: f<N>
File: ...
...

For previously rejected findings, respond with ONE of:
ACCEPTED_REJECTION: f<N> — I agree with the reasoning.
INSIST: f<N> — <stronger argument why this must be fixed>

If everything is resolved:
CONSENSUS: All findings resolved. Code is in good shape.
```

---

## Template 3: Final Consensus Check

Used when Claude believes all issues are resolved and wants peer confirmation. This prompt should always run in a fresh peer session, not a resumed one.

```markdown
This is the final review round. All previous findings have been addressed.
Perform an independent final check against the current local repository state.
Inspect the current local repository state directly and confirm the final code is acceptable.

[WORKSPACE]
Repository root: {repo_root}

[FILES TO VERIFY]
{final_target_files}

[RESOLUTION SUMMARY]
| Finding | Severity | Resolution |
|---------|----------|------------|
{resolution_table_rows}

Please respond with ONE of:
- CONSENSUS: Approved — if you are satisfied with the current code state
- Any remaining concerns as standard FINDING entries
```

---

## Placeholder Reference

| Placeholder | Source | Description |
|-------------|--------|-------------|
| `{project_description}` | CLAUDE.md or package.json name/description | Brief project context |
| `{repo_root}` | Current working directory | Absolute path to the repository root |
| `{scope_type}` | Phase 0 detection | "local-diff", "pr-42", "commit-abc1234" |
| `{scope_detail}` | Phase 0 detection | Human-readable summary of the review scope |
| `{target_files}` | Preflight file list | Newline-separated files for the peer to inspect locally |
| `{project_context}` | CLAUDE.md + key config files | Project conventions and rules |
| `{round_target_files}` | `git diff --name-only HEAD~1 HEAD` or latest touched files | Files to re-open during re-review |
| `{accepted_findings_summary}` | rounds.json claude_actions where action=accept | List of what was fixed (`claude_actions` is the historical schema field name) |
| `{rejected_findings_with_reasoning}` | rounds.json claude_actions where action=reject | Each entry includes reasoning AND the verbatim `Verification:` block from `claude_actions[].verification` (`claude_actions` is the historical schema field name) |
| `{final_target_files}` | Union of files touched across the session | Files to verify in the final consensus round |
| `{resolution_table_rows}` | Generated from rounds.json summary | Markdown table rows |
