#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

engine="${HARNESS_ENGINE_SCRIPT:-$repo_root/plugins/harness-engineering-skills/skills/harness/scripts/harness-engine.sh}"
execution_protocol="${HARNESS_EXECUTION_PROTOCOL:-$repo_root/plugins/harness-engineering-skills/skills/harness/references/execution-protocol.md}"
quick_ref="${HARNESS_PROTOCOL_QUICK_REF:-$repo_root/plugins/harness-engineering-skills/skills/harness/references/protocol-quick-ref.md}"

for file in "$engine" "$execution_protocol" "$quick_ref"; do
  if [[ ! -f "$file" ]]; then
    echo "missing required file: $file" >&2
    exit 1
  fi
done

if ! grep -Eq '^[[:space:]]*create-pr\)' "$engine"; then
  echo "engine dispatch table is missing create-pr command" >&2
  exit 1
fi

engine_tokens=(
  "CREATE_PR_OK"
  "PR_HANDOFF_OK"
)

for token in "${engine_tokens[@]}"; do
  if ! grep -Fq "$token" "$engine"; then
    echo "engine create-pr implementation is missing token: $token" >&2
    exit 1
  fi
done

protocol_tokens=(
  "\$ENGINE create-pr"
  "CREATE_PR_OK"
  "PR_HANDOFF_OK"
  "\$ENGINE pass-pr"
)

for token in "${protocol_tokens[@]}"; do
  if ! grep -Fq "$token" "$execution_protocol"; then
    echo "execution protocol is missing create-pr wiring token: $token" >&2
    exit 1
  fi
done

quick_ref_tokens=(
  "create-pr --base"
  "CREATE_PR_OK"
  "PR_HANDOFF_OK"
  "pass-pr --pr-url"
)

for token in "${quick_ref_tokens[@]}"; do
  if ! grep -Fq "$token" "$quick_ref"; then
    echo "protocol quick-ref is missing create-pr command token: $token" >&2
    exit 1
  fi
done

pr_step="$(
  awk '
    /^7\. PR creation/ { in_section=1; print; next }
    in_section && /^8\. / { exit }
    in_section { print }
  ' "$execution_protocol"
)"

if [[ -z "$pr_step" ]]; then
  echo "execution protocol is missing the PR creation step section" >&2
  exit 1
fi

primary_path="$(
  awk '
    /PR_HANDOFF_OK/ { exit }
    { print }
  ' <<<"$pr_step"
)"

legacy_primary_tokens=(
  "ship"
  "superpowers:finishing-a-development-branch"
  "gh pr create"
)

for token in "${legacy_primary_tokens[@]}"; do
  if grep -Fq "$token" <<<"$primary_path"; then
    echo "execution protocol routes primary PR creation through legacy path before PR_HANDOFF_OK: $token" >&2
    exit 1
  fi
done

echo "create-pr protocol wiring check passed"
