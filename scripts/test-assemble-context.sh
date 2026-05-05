#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
engine="$repo_root/plugins/harness-engineering-skills/skills/harness/scripts/harness-engine.sh"
tmp_tasks=()

cleanup() {
  for task in "${tmp_tasks[@]:-}"; do
    rm -rf "$repo_root/.harness/$task"
  done
}
trap cleanup EXIT INT TERM

new_task() {
  local task="$1"
  tmp_tasks+=("$task")
  mkdir -p "$repo_root/.harness/$task"
  cat > "$repo_root/.harness/$task/git-state.json" <<JSON
{
  "task_id": "$task",
  "task_start_sha": "test",
  "phase": "checkpoints",
  "checkpoints": {},
  "e2e_baseline_sha": "",
  "e2e_final_sha": "",
  "review_loop_status": "",
  "review_loop_session_id": "",
  "review_loop_summary_file": "",
  "review_loop_rounds_file": "",
  "full_verify_baseline_sha": "",
  "full_verify_final_sha": "",
  "full_verify_status": "",
  "pr_url": ""
}
JSON
}

write_spec() {
  local task="$1"
  local type_line="$2"
  cat > "$repo_root/.harness/$task/spec.md" <<SPEC
---
task_id: $task
title: assemble context parser fixture
version: 1
status: approved
branch: test
---

## Goal

Exercise checkpoint parsing.

## Checkpoints

### Checkpoint 01: fixture checkpoint

- Scope: fixture scope
- Depends on: none
$type_line
- Acceptance criteria:
  - [ ] keep acceptance bullet
- Files of interest:
  - fixture.txt
- Effort estimate: S
SPEC
}

assert_context_type() {
  local task="$1"
  local expected="$2"
  "$engine" assemble-context --task-id "$task" --checkpoint 01 >/dev/null
  grep -q "^checkpoint_type: $expected$" "$repo_root/.harness/$task/checkpoints/01/context.md"
}

canonical_task="assemble-context-canonical-$$"
new_task "$canonical_task"
write_spec "$canonical_task" "- Type: backend"
assert_context_type "$canonical_task" "backend"

bold_task="assemble-context-bold-$$"
new_task "$bold_task"
write_spec "$bold_task" "- **Type**: backend"
assert_context_type "$bold_task" "backend"

missing_task="assemble-context-missing-$$"
new_task "$missing_task"
write_spec "$missing_task" "- Depends on: none"
if "$engine" assemble-context --task-id "$missing_task" --checkpoint 01 >"$repo_root/.harness/$missing_task/stdout.txt" 2>"$repo_root/.harness/$missing_task/stderr.txt"; then
  echo "expected assemble-context to fail for missing Type field" >&2
  exit 1
fi
grep -Eq "Error: checkpoint 01 missing or invalid Type field at .*spec.md:[0-9]+" "$repo_root/.harness/$missing_task/stderr.txt"

code_task="assemble-context-code-heading-$$"
new_task "$code_task"
cat > "$repo_root/.harness/$code_task/spec.md" <<'SPEC'
---
task_id: assemble-context-code-heading
title: code heading fixture
version: 1
status: approved
branch: test
---

## Goal

Exercise checkpoint parsing with markdown-looking code.

## Checkpoints

### Checkpoint 01: fixture checkpoint

- Scope: fixture scope with inline `## Not a real sibling heading`
- Depends on: none
- Type: infrastructure
- Acceptance criteria:
  - [ ] keep acceptance bullet after inline code

```markdown
## Not a real sibling heading
### Checkpoint 99: not real either
```

- Files of interest:
  - fixture.txt
- Effort estimate: S

### Checkpoint 02: next real checkpoint

- Scope: next fixture
- Depends on: none
- Type: infrastructure
- Acceptance criteria:
  - [ ] next bullet
- Files of interest:
  - next.txt
- Effort estimate: S
SPEC

assert_context_type "$code_task" "infrastructure"
grep -q "keep acceptance bullet after inline code" "$repo_root/.harness/$code_task/checkpoints/01/context.md"
grep -q "fixture.txt" "$repo_root/.harness/$code_task/checkpoints/01/context.md"
if grep -q "next fixture" "$repo_root/.harness/$code_task/checkpoints/01/context.md"; then
  echo "checkpoint 01 context leaked into checkpoint 02" >&2
  exit 1
fi

echo "assemble-context parser tests passed"
