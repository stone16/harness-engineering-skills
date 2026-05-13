#!/usr/bin/env python3
"""Normalize and validate agent result artifacts to raw YAML frontmatter contract.

Agent processes (Claude, Codex, Gemini) sometimes wrap their final-result text
in markdown code fences, prefix the YAML frontmatter with a list-item marker
(``- ---``), or emit leading blank lines. The harness engine's frontmatter
parser requires the artifact's first three characters to be raw ``---`` and a
matching closing ``---`` line; malformed shapes force the operator to normalize
by hand before the verdict can be consumed.

This helper centralizes the normalize-and-validate logic so every agent-invoke
script (claude-agent-invoke.sh today, codex/gemini counterparts when #34
lands) can call into one implementation rather than each open-coding its own.

CLI usage::

    normalize_claude_artifact.py \\
        --agent <agent-name> \\
        --result-file <path-to-raw-result> \\
        --output-file <path-to-write> \\
        [--existing-file <path-to-current-artifact>]

Exit codes:

* 0 — normalized artifact written, or existing artifact preserved
* 2 — malformed input and no preservable existing artifact; parse-error YAML
      written to output_file
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys


_LEADING_FENCE_RE = re.compile(r"\A```[A-Za-z0-9_+-]*[ \t]*\r?\n")
_TRAILING_FENCE_RE = re.compile(r"\r?\n```[ \t]*\r?\n?[ \t]*\Z")


def normalize_and_validate(text: str) -> tuple[str, str | None]:
    """Normalize agent result text and validate raw YAML frontmatter contract.

    Returns ``(normalized_text, error)`` where ``error`` is ``None`` on success
    and a human-readable diagnostic string when the contract is violated.

    Normalization steps (applied in order):

    1. Strip leading whitespace and blank lines.
    2. Strip a leading markdown code fence (e.g. ``` ```yaml ```` ``` ``` ``)
       and, if present, the matching trailing fence.
    3. Strip a leading ``- `` list-item prefix from a ``- ---`` first line.
    4. Re-trim leading blank lines after normalization.

    Validation:

    * First non-empty line MUST be exactly ``---``.
    * A closing ``---`` line MUST appear somewhere after the opener.
    """
    work = text.lstrip()

    fence_match = _LEADING_FENCE_RE.match(work)
    if fence_match:
        work = work[fence_match.end():]
        trailing_match = _TRAILING_FENCE_RE.search(work)
        if trailing_match:
            work = work[: trailing_match.start()] + "\n"

    if work.startswith("- ---"):
        work = work[2:]

    work = work.lstrip("\n")

    lines = work.splitlines()
    if not lines:
        return work, "result is empty after normalization"

    first_line = lines[0].rstrip()
    if first_line != "---":
        sample = first_line if len(first_line) <= 120 else first_line[:117] + "..."
        return work, (
            f"first non-empty line is not '---' "
            f"(got {sample!r}; expected raw YAML frontmatter opener)"
        )

    has_closing = any(line.rstrip() == "---" for line in lines[1:])
    if not has_closing:
        return work, "no closing '---' line found after opening frontmatter"

    return work, None


def _has_valid_opening(text: str) -> bool:
    stripped = text.lstrip()
    if not stripped:
        return False
    first_line = stripped.splitlines()[0].rstrip()
    return first_line == "---"


def _build_parse_error_artifact(
    agent: str, error: str, raw_text: str
) -> str:
    """Produce a YAML-framed parse-error artifact the engine can consume."""
    first_nonempty = next(
        (line for line in raw_text.splitlines() if line.strip()),
        "",
    )
    sample = first_nonempty if len(first_nonempty) <= 200 else first_nonempty[:197] + "..."
    indented_raw = "\n".join(f"  {line}" for line in raw_text.splitlines())
    return (
        "---\n"
        "result: parse-error\n"
        f"agent: {agent}\n"
        "reason: malformed-artifact-shape\n"
        f"detail: {_yaml_inline(error)}\n"
        f"first_line: {_yaml_inline(sample)}\n"
        "---\n"
        "\n"
        "The agent's final result did not conform to the raw YAML frontmatter\n"
        "contract. The engine's frontmatter parser requires the artifact's first\n"
        "non-empty line to be exactly `---` and a matching closing `---` line to\n"
        "appear later. See `reason` and `detail` above for the specific\n"
        "violation. Raw agent output is preserved verbatim below for retro:\n"
        "\n"
        "```\n"
        f"{indented_raw}\n"
        "```\n"
    )


def _yaml_inline(value: str) -> str:
    """Quote a value safely for a single-line YAML scalar."""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _process(
    agent: str,
    result_file: pathlib.Path,
    output_file: pathlib.Path,
    existing_file: pathlib.Path | None,
) -> int:
    if not result_file.exists():
        sys.stderr.write(f"Error: result file not found: {result_file}\n")
        return 2

    raw_text = result_file.read_text()
    normalized, error = normalize_and_validate(raw_text)

    if error is None:
        output_file.parent.mkdir(parents=True, exist_ok=True)
        output_file.write_text(normalized)
        return 0

    existing_text = ""
    if existing_file and existing_file.exists():
        existing_text = existing_file.read_text()

    if existing_text.strip() and _has_valid_opening(existing_text):
        sys.stderr.write(
            f"Warning: agent {agent!r} returned non-frontmatter result "
            f"({error}); preserving existing on-disk artifact at {existing_file}\n"
        )
        return 0

    parse_error_yaml = _build_parse_error_artifact(agent, error, raw_text)
    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(parse_error_yaml)
    sys.stderr.write(
        f"Error: agent {agent!r} emitted malformed artifact ({error}). "
        f"Parse-error YAML written to {output_file}.\n"
    )
    return 2


def main(argv: list[str] | None = None) -> int:
    summary = (__doc__ or "Normalize agent artifacts.").splitlines()[0]
    parser = argparse.ArgumentParser(description=summary)
    parser.add_argument("--agent", required=True, help="Agent name for diagnostics")
    parser.add_argument(
        "--result-file",
        required=True,
        type=pathlib.Path,
        help="Path to raw result text from the agent",
    )
    parser.add_argument(
        "--output-file",
        required=True,
        type=pathlib.Path,
        help="Path to write the normalized (or parse-error) artifact",
    )
    parser.add_argument(
        "--existing-file",
        type=pathlib.Path,
        default=None,
        help="Optional path checked when result is malformed; if it contains a "
        "valid frontmatter opener, preserve it instead of overwriting",
    )
    args = parser.parse_args(argv)
    return _process(args.agent, args.result_file, args.output_file, args.existing_file)


if __name__ == "__main__":
    raise SystemExit(main())
