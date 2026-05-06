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

extract_section() {
  local file="$1"
  local start_regex="$2"
  local next_regex="$3"
  awk -v start="$start_regex" -v stop_re="$next_regex" '
    $0 ~ start { in_section=1; print; next }
    in_section && $0 ~ stop_re { exit }
    in_section { print }
  ' "$file"
}

quick_ref_section="$(
  awk '
    /^## review-loop-fullverify-coupling$/ { in_section=1; print; next }
    in_section && /^## / { exit }
    in_section { print }
  ' "$quick_ref"
)"

if [[ -z "$quick_ref_section" ]]; then
  echo "missing ## review-loop-fullverify-coupling section in $quick_ref" >&2
  exit 1
fi

synthesis_section="$(extract_section "$synthesis_protocol" '^## 6\. Harness Full-Verify Coupling$' '^## ')"
if [[ -z "$synthesis_section" ]]; then
  echo "missing ## 6. Harness Full-Verify Coupling section in $synthesis_protocol" >&2
  exit 1
fi

review_loop_scope_section="$(extract_section "$review_loop_skill" '^### Documentation / Protocol Scope Rule' '^### ')"
if [[ -z "$review_loop_scope_section" ]]; then
  echo "missing Documentation / Protocol Scope Rule section in $review_loop_skill" >&2
  exit 1
fi

keywords=(
  "discovery-gate mirror"
  "post-fix integration audit"
  "async lifecycle heuristic"
)

for keyword in "${keywords[@]}"; do
  if ! grep -Fq "$keyword" <<<"$quick_ref_section"; then
    echo "missing keyword in protocol section: $keyword" >&2
    exit 1
  fi

  if ! grep -Fq "$keyword" <<<"$synthesis_section"; then
    echo "missing keyword in synthesis coupling section: $keyword" >&2
    exit 1
  fi
done

for keyword in "fresh-final" "docs/protocol scope" "load-bearing"; do
  if ! grep -Fq "$keyword" <<<"$review_loop_scope_section"; then
    echo "missing keyword in review-loop protocol-scope section: $keyword" >&2
    exit 1
  fi
done

echo "review-loop fullverify rule mirror check passed"
