#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

quick_ref="${HARNESS_REVIEW_LOOP_FULLVERIFY_QUICK_REF:-$repo_root/plugins/harness-engineering-skills/skills/harness/references/protocol-quick-ref.md}"
review_loop_skill="${HARNESS_REVIEW_LOOP_SKILL:-$repo_root/plugins/harness-engineering-skills/skills/review-loop/SKILL.md}"
synthesis_protocol="${HARNESS_REVIEW_LOOP_SYNTHESIS:-$repo_root/plugins/harness-engineering-skills/skills/review-loop/references/synthesis-protocol.md}"

for file in "$quick_ref" "$review_loop_skill" "$synthesis_protocol"; do
  if [[ ! -f "$file" ]]; then
    echo "missing required file: $file" >&2
    exit 1
  fi
done

section="$(
  awk '
    /^## review-loop-fullverify-coupling$/ { in_section=1; print; next }
    in_section && /^## / { exit }
    in_section { print }
  ' "$quick_ref"
)"

if [[ -z "$section" ]]; then
  echo "missing ## review-loop-fullverify-coupling section in $quick_ref" >&2
  exit 1
fi

keywords=(
  "discovery-gate mirror"
  "post-fix integration audit"
  "async lifecycle heuristic"
)

for keyword in "${keywords[@]}"; do
  if ! grep -Fq "$keyword" <<<"$section"; then
    echo "missing keyword in protocol section: $keyword" >&2
    exit 1
  fi

  if ! grep -Fq "$keyword" "$review_loop_skill" && ! grep -Fq "$keyword" "$synthesis_protocol"; then
    echo "missing downstream review-loop mirror keyword: $keyword" >&2
    exit 1
  fi
done

echo "review-loop fullverify rule mirror check passed"
