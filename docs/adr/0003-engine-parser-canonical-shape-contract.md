# Engine Parser Canonical Shape Contract

## Status

Accepted

## Date

2026-05-05

## Deciders

- Harness maintainers

## Context

Prior retros filed issues #8, #15, #19, and #25 after checkpoint context
assembly silently produced `checkpoint_type: unknown` or truncated checkpoint
sections when specs used markdown decoration or markdown-looking code samples.
That made execution depend on orchestrator luck: a backend or infrastructure
checkpoint could be evaluated under the wrong testing strategy, and inline or
fenced examples could hide acceptance criteria from the Generator.

## Decision Drivers

- Engine context must be deterministic and fail loud when required metadata is
  missing.
- The canonical spec schema should remain in `protocol-quick-ref.md`, not in
  ADR prose.
- Legacy specs using a bold-decorated Type line should not silently degrade.
- Markdown code examples must not be treated as real checkpoint boundaries.

## Options Considered

- Keep permissive grep-based extraction and rely on humans to notice
  `checkpoint_type: unknown`.
- Accept every markdown decoration variant as equally canonical.
- Accept one compatibility shape, warn during spec review, and fail loudly on
  missing or invalid metadata.

## Decision

Use a line-aware checkpoint parser in `harness-engine.sh` that walks real
markdown headings while ignoring fenced code blocks. The engine accepts the
canonical `- Type: <value>` line and one compatibility form,
`- **Type**: <value>`, but missing or invalid Type metadata exits non-zero with
a spec line reference. The Spec Evaluator warns on the decorated form and asks
the Planner to normalize to the canonical line.

## Consequences

- Positive: invalid specs fail at context assembly instead of flowing into
  checkpoint execution as `unknown`.
- Positive: legacy bold Type specs remain executable while being nudged toward
  the canonical schema.
- Negative: specs that previously ran with missing Type fields now require a
  small metadata fix before execution.
- Neutral: the canonical regex and file-format contract remain in
  `protocol-quick-ref.md`; this ADR records rationale only.

## Validation

`scripts/test-assemble-context.sh` covers canonical Type, bold Type,
missing Type fail-loud behavior, and markdown-looking headings inside inline
or fenced code.

## Related ADRs

- docs/adr/0001-convention-scout-and-host-repo-doc-gap.md
- docs/adr/0002-retro-issue-routing.md

## External References

- GitHub issues #8, #15, #19, #25
