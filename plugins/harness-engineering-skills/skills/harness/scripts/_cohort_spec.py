#!/usr/bin/env python3
"""Shared parsing helpers for harness cohort specs.

The harness engine is intentionally shell-first, but cohort safety relies on
the same Markdown metadata parsing in multiple commands. Keep those parser
rules here so fixes to decoration/path handling do not drift across call sites.
"""

from __future__ import annotations

import json
import pathlib
import re
import subprocess
import sys
from collections.abc import Iterable


METADATA_FIELDS = (
    "Scope",
    "Depends on",
    "Type",
    "parallel_group",
    "Acceptance criteria",
    "Effort estimate",
)


def strip_inline_code(text: str) -> str:
    """Remove Markdown backtick markers while preserving their contents."""

    return re.sub(r"`([^`]*)`", r"\1", text)


def canon_path(path: str) -> str:
    value = path.strip()
    value = re.sub(r"\s+\(new\)\s*$", "", value)
    while value.startswith("./"):
        value = value[2:]
    return value.strip()


def normalize_cp(value: str) -> str:
    match = re.search(r"CP\s*0*([0-9]+)", value, re.IGNORECASE)
    if not match:
        return ""
    return f"{int(match.group(1)):02d}"


def checkpoint_sections(text: str) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = {}
    current: str | None = None
    current_lines: list[str] = []
    in_fence = False
    for line in text.splitlines():
        if line.strip().startswith("```"):
            in_fence = not in_fence
        match = re.match(r"^### Checkpoint ([0-9]{2}):", line)
        if match and not in_fence:
            if current:
                sections[current] = current_lines
            current = match.group(1)
            current_lines = [line]
        elif current:
            current_lines.append(line)
    if current:
        sections[current] = current_lines
    return sections


def _metadata_match(line: str) -> re.Match[str] | None:
    fields = "|".join(re.escape(field) for field in METADATA_FIELDS)
    return re.match(rf"^\s*-\s*(?:\*\*)?(?:{fields})(?:\*\*)?\b", line, re.IGNORECASE)


def _split_paths(value: str) -> Iterable[str]:
    for part in value.split(","):
        path = canon_path(part)
        if path:
            yield path


def parse_section(lines: list[str]) -> dict[str, object]:
    meta: dict[str, object] = {"group": "", "depends": set(), "files": set()}
    in_fence = False
    in_files = False
    for raw_line in lines:
        line = raw_line.rstrip("\n")
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue

        no_inline = strip_inline_code(line)
        group_match = re.match(r"^\s*-\s*(?:\*\*)?parallel_group(?:\*\*)?:\s*(\S+)\s*$", no_inline)
        if group_match:
            meta["group"] = group_match.group(1).strip()
            in_files = False
            continue

        depends_match = re.match(r"^\s*-\s*(?:\*\*)?Depends on(?:\*\*)?:\s*(.*)$", no_inline, re.IGNORECASE)
        if depends_match:
            in_files = False
            dep_text = depends_match.group(1)
            depends = meta["depends"]
            assert isinstance(depends, set)
            for dep in re.findall(r"CP\s*0*[0-9]+", dep_text, re.IGNORECASE):
                cp = normalize_cp(dep)
                if cp:
                    depends.add(cp)
            continue

        files_match = re.match(r"^\s*-\s*(?:\*\*)?Files of interest(?:\*\*)?:\s*(.*)$", no_inline, re.IGNORECASE)
        if files_match:
            in_files = True
            files = meta["files"]
            assert isinstance(files, set)
            files.update(_split_paths(files_match.group(1).strip()))
            continue

        if _metadata_match(no_inline):
            in_files = False

        if in_files:
            item_match = re.match(r"^\s*-\s*(.+)$", no_inline)
            if item_match:
                files = meta["files"]
                assert isinstance(files, set)
                files.update(_split_paths(item_match.group(1)))
    return meta


def files_of_interest(lines: list[str]) -> list[str]:
    files: list[str] = []
    seen: set[str] = set()
    for path in sorted(parse_section(lines)["files"]):
        if path not in seen:
            files.append(path)
            seen.add(path)
    return files


def cmd_begin_cohort(argv: list[str]) -> int:
    spec_path = pathlib.Path(argv[0])
    state_path = pathlib.Path(argv[1])
    group = argv[2]
    baseline_sha = argv[3]
    out_path = pathlib.Path(argv[4])
    enable_parallel_cohorts = argv[5].lower()
    max_parallel_cohort_size = int(argv[6])

    sections = checkpoint_sections(spec_path.read_text())
    if not sections:
        print(f"Error: no checkpoints found in {spec_path}", file=sys.stderr)
        return 1

    parsed = {cp: parse_section(lines) for cp, lines in sections.items()}
    explicit_members = [cp for cp, meta in parsed.items() if meta["group"] == group]
    if explicit_members:
        members = sorted(explicit_members)
    else:
        members = [group] if group in parsed and not parsed[group]["group"] else []

    if not members:
        print(f"Error: cohort {group} has no members in {spec_path}", file=sys.stderr)
        return 1

    if len(members) > 1 and enable_parallel_cohorts == "false":
        print(
            f"Error: enable_parallel_cohorts=false; cohort {group} has {len(members)}>1 members",
            file=sys.stderr,
        )
        return 1

    if len(members) > max_parallel_cohort_size:
        print(
            f"Error: cohort {group} has {len(members)} members; "
            f"max_parallel_cohort_size={max_parallel_cohort_size}",
            file=sys.stderr,
        )
        return 1

    member_set = set(members)
    for cp in members:
        depends = parsed[cp]["depends"]
        assert isinstance(depends, set)
        for dep in sorted(depends):
            if dep in member_set:
                first, second = sorted([cp, dep])
                print(
                    f"Error: cohort {group} members CP{first} and CP{second} have Depends on edge; "
                    f"same-group members must be independent ({spec_path})",
                    file=sys.stderr,
                )
                return 1

    if len(members) > 1:
        for cp in members:
            files = parsed[cp]["files"]
            assert isinstance(files, set)
            if not files:
                print(
                    f"Error: cohort {group} member CP{cp} has empty Files of interest; "
                    f"multi-member cohorts require disjoint explicit files ({spec_path})",
                    file=sys.stderr,
                )
                return 1

    for idx, cp_a in enumerate(members):
        files_a = parsed[cp_a]["files"]
        assert isinstance(files_a, set)
        for cp_b in members[idx + 1 :]:
            files_b = parsed[cp_b]["files"]
            assert isinstance(files_b, set)
            overlap = sorted(files_a & files_b)
            if overlap:
                print(
                    f"Error: cohort {group} members CP{cp_a} and CP{cp_b} have overlapping "
                    f"Files of interest path {overlap[0]} at {spec_path}",
                    file=sys.stderr,
                )
                return 1

    state = json.loads(state_path.read_text())
    state["phase"] = "checkpoints"
    cohorts = state.setdefault("cohorts", {})
    cohorts[group] = {
        "members": members,
        "status": "pending",
        "baseline_sha": baseline_sha,
    }
    checkpoints = state.setdefault("checkpoints", {})
    for cp in members:
        checkpoints.setdefault(cp, {})["cohort"] = group

    out_path.write_text(json.dumps(state, indent=2) + "\n")
    print(",".join(members))
    return 0


def cmd_drift_shadow(argv: list[str]) -> int:
    spec_path = pathlib.Path(argv[0])
    state_path = pathlib.Path(argv[1])
    checkpoint = argv[2]
    cohort = argv[3]
    iter_dir = pathlib.Path(argv[4])
    iteration = argv[5]
    changed = [line for line in argv[6].splitlines() if line.strip()]

    state = json.loads(state_path.read_text())
    members = state.get("cohorts", {}).get(cohort, {}).get("members", [])
    if checkpoint not in members:
        return 0

    sections = checkpoint_sections(spec_path.read_text())
    own_files = set(files_of_interest(sections.get(checkpoint, [])))
    peer_files: dict[str, str] = {}
    for member in members:
        if member == checkpoint:
            continue
        for path in files_of_interest(sections.get(member, [])):
            peer_files.setdefault(path, member)

    for raw_path in changed:
        path = canon_path(raw_path)
        peer = peer_files.get(path)
        if peer and path not in own_files:
            detected_at = subprocess.check_output(
                ["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], text=True
            ).strip()
            (iter_dir / "drift-event.md").write_text(
                "---\n"
                f"offending_path: {path}\n"
                f"offending_checkpoint: {checkpoint}\n"
                f"peer_checkpoint: {peer}\n"
                "severity: shadow\n"
                f"detected_at: {detected_at}\n"
                "---\n\n"
                "Drift detected. The iteration reports FAIL while this audit artifact remains available.\n"
            )
            print("DRIFT_DETECTED")
            print(f"TASK_ID={state.get('task_id', '')}")
            print(f"CHECKPOINT={checkpoint}")
            print(f"ITERATION={iteration}")
            print(f"OFFENDING_PATH={path}")
            print(f"PEER_CHECKPOINT={peer}")
            return 66
    return 0


def cmd_peer_restrictions(argv: list[str]) -> int:
    spec_path = pathlib.Path(argv[0])
    state_path = pathlib.Path(argv[1])
    checkpoint = argv[2]

    state = json.loads(state_path.read_text())
    cp = state.get("checkpoints", {}).get(checkpoint, {})
    cohort = cp.get("cohort", "")
    if not cohort:
        return 0

    members = state.get("cohorts", {}).get(cohort, {}).get("members", [])
    peers = [member for member in members if member != checkpoint]
    if not peers:
        return 0

    sections = checkpoint_sections(spec_path.read_text())
    print("## Peer Cohort Restrictions")
    print("")
    print(
        f"Checkpoint {checkpoint} is in cohort `{cohort}`. Do not touch peer cohort files; "
        "end-iteration reports `DRIFT_DETECTED` if this checkpoint changes a peer-owned path."
    )
    print("")
    for peer in peers:
        files = files_of_interest(sections.get(peer, []))
        print(f"- CP{peer}:")
        if files:
            for path in files:
                print(f"  - {path}")
        else:
            print("  - (no Files of interest declared)")
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print("Usage: _cohort_spec.py <begin-cohort|drift-shadow|peer-restrictions> ...", file=sys.stderr)
        return 2
    command, rest = argv[0], argv[1:]
    if command == "begin-cohort":
        if len(rest) != 7:
            print("begin-cohort expects 7 arguments", file=sys.stderr)
            return 2
        return cmd_begin_cohort(rest)
    if command == "drift-shadow":
        if len(rest) != 7:
            print("drift-shadow expects 7 arguments", file=sys.stderr)
            return 2
        return cmd_drift_shadow(rest)
    if command == "peer-restrictions":
        if len(rest) != 3:
            print("peer-restrictions expects 3 arguments", file=sys.stderr)
            return 2
        return cmd_peer_restrictions(rest)
    print(f"Unknown command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
