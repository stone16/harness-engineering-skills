#!/usr/bin/env bash
set -euo pipefail

# Regression test for issue #36: review-loop preflight.sh checkpoint commit
# must NOT use `git add -A` because that sweeps cross-task .harness/ scratch
# and any other untracked workspace junk onto the feature branch under
# review, defeating the peer-review scope.
#
# This test creates a workspace with:
#   - A tracked file modified since last commit (in scope, should commit)
#   - An untracked file under .harness/some-other-task/ (out of scope,
#     must NOT commit — that's the bug the fix addresses)
#   - An untracked file at workspace root (out of scope, must NOT commit,
#     but operator should see a warning naming it)
#
# Asserts:
#   - The checkpoint commit contains only the tracked-modified change.
#   - The .harness/ scratch is still untracked after preflight.
#   - stderr carries a warning naming the root-level untracked file.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
preflight="$repo_root/plugins/harness-engineering-skills/skills/review-loop/scripts/preflight.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

# Stub a fake `codex` CLI so preflight doesn't bail on "peer not found".
fake_bin="$tmpdir/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/codex" <<'STUB'
#!/usr/bin/env bash
echo "fake codex called: $*"
STUB
chmod +x "$fake_bin/codex"
export PATH="$fake_bin:$PATH"

scenarios_run=0
scenario() {
  scenarios_run=$((scenarios_run + 1))
  printf '[%d] %s\n' "$scenarios_run" "$1"
}

assert_no_match_in_commit() {
  local pattern="$1"
  if git -C "$repo" log -1 --name-only --pretty=format: | grep -Fq -- "$pattern"; then
    echo "FAIL: checkpoint commit unexpectedly contains '$pattern':" >&2
    git -C "$repo" log -1 --name-only --pretty=format: >&2
    exit 1
  fi
}

assert_match_in_commit() {
  local pattern="$1"
  if ! git -C "$repo" log -1 --name-only --pretty=format: | grep -Fq -- "$pattern"; then
    echo "FAIL: checkpoint commit missing expected '$pattern':" >&2
    git -C "$repo" log -1 --name-only --pretty=format: >&2
    exit 1
  fi
}

assert_path_still_untracked() {
  local path="$1"
  if ! git -C "$repo" ls-files --others --exclude-standard | grep -Fxq -- "$path"; then
    echo "FAIL: expected '$path' to still be untracked after preflight" >&2
    git -C "$repo" status --short >&2
    exit 1
  fi
}

scenario "preflight commits tracked-modified only; cross-task .harness/ scratch is left untracked"
repo="$tmpdir/repo"
origin="$tmpdir/origin.git"
git init -q --bare "$origin"
git clone -q "$origin" "$repo"
(
  cd "$repo"
  git checkout -q -b feat/branch
  git config user.email "test@example.com"
  git config user.name "Preflight Test"
  echo "v1" > tracked.txt
  git add tracked.txt
  git commit -q -m "initial"
  git push -q -u origin feat/branch
  # ── Modify a tracked file (should land in checkpoint commit) ──
  echo "v2" > tracked.txt
  # ── Untracked harness scratch from a different task (should NOT land) ──
  mkdir -p .harness/some-other-task/checkpoints/cp01/iter-1
  echo "scratch" > .harness/some-other-task/checkpoints/cp01/iter-1/output-summary.md
  # ── Untracked root-level file (should NOT land; should warn) ──
  echo "leftover" > extra.txt
)

stderr_file="$tmpdir/preflight.stderr"
(
  cd "$repo"
  "$preflight" --peer codex --max-rounds 1 --scope diff 2>"$stderr_file" >/dev/null
)

# Tracked-modified file is in the checkpoint commit
assert_match_in_commit "tracked.txt"
# Harness scratch is NOT in the commit and is still untracked
assert_no_match_in_commit ".harness/some-other-task/checkpoints/cp01/iter-1/output-summary.md"
assert_path_still_untracked ".harness/some-other-task/checkpoints/cp01/iter-1/output-summary.md"
# Root-level untracked file is NOT in the commit and is still untracked
assert_no_match_in_commit "extra.txt"
assert_path_still_untracked "extra.txt"
# Operator saw a warning naming the root-level untracked file
if ! grep -Fq "extra.txt" "$stderr_file"; then
  echo "FAIL: expected stderr to warn about 'extra.txt'; got:" >&2
  cat "$stderr_file" >&2
  exit 1
fi
# The scratch path should NOT appear in the warning (it's in the excluded set)
if grep -Fq ".harness/some-other-task" "$stderr_file"; then
  echo "FAIL: stderr should not name excluded .harness/ scratch:" >&2
  cat "$stderr_file" >&2
  exit 1
fi

scenario "preflight on a clean workspace produces an --allow-empty checkpoint commit"
repo="$tmpdir/repo2"
origin="$tmpdir/origin2.git"
git init -q --bare "$origin"
git clone -q "$origin" "$repo"
(
  cd "$repo"
  git checkout -q -b feat/branch2
  git config user.email "test@example.com"
  git config user.name "Preflight Test"
  echo "v1" > tracked.txt
  git add tracked.txt
  git commit -q -m "initial"
  echo "v2" > tracked.txt  # need a diff so scope=diff resolves
  git add tracked.txt
  git commit -q -m "round-baseline"
  git push -q -u origin feat/branch2
  # Make a small tracked change so preflight finds local-diff scope
  echo "v3" > tracked.txt
)

(
  cd "$repo"
  "$preflight" --peer codex --max-rounds 1 --scope diff 2>/dev/null >/dev/null
)

# Checkpoint commit exists at HEAD with the expected message
last_msg="$(git -C "$repo" log -1 --pretty=%s)"
if [[ "$last_msg" != "review-loop: checkpoint before round 1" ]]; then
  echo "FAIL: expected last commit message 'review-loop: checkpoint before round 1', got '$last_msg'" >&2
  exit 1
fi

echo "preflight scoped-staging test passed ($scenarios_run scenarios)"
