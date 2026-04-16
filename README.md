<p align="center"><a href="README.md">English</a> | <a href="README.zh-CN.md">中文</a></p>

# Harness Engineering Skills

Stometa's public curated Claude Code skillset — a small, opinionated set of skills we use ourselves, published periodically.

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Claude Code](https://img.shields.io/badge/Claude_Code-Plugin-blueviolet)](https://claude.ai/claude-code)
[![Peer: Codex](https://img.shields.io/badge/peer-Codex_CLI-74aa9c)](https://github.com/openai/codex)
[![Peer: Gemini](https://img.shields.io/badge/peer-Gemini_CLI-4285F4)](https://github.com/google-gemini/gemini-cli)

## Why this repo

This is the **public** companion to Stometa's private `stometa-skillset`. We dogfood a larger internal skillset day-to-day; selected skills are extracted, polished, and published here in batches. The goal is to share the workflows that actually hold up under real engineering work — not a pile of prototypes.

The first batch ships two skills: `review-loop` (already proven in daily use) and `harness` (multi-agent orchestration for larger tasks). Both are installable as a single Claude Code plugin.

## Skills

### `review-loop`

Cross-LLM iterative code review. Spawns a peer reviewer (Codex CLI or Gemini CLI) to independently review your changes. Claude evaluates the peer's findings, implements accepted fixes, and re-submits until both sides agree on the final code state. The human doesn't need to participate — watch progress via `.review-loop/<session>/summary.md`.

### `harness`

Cybernetics-based multi-agent orchestration for complex tasks. Coordinates a **Planner → Generator → Evaluator → Retro** pipeline with fresh sub-agents per checkpoint (drift prevention) and persistent retro learning across tasks. Recommended flow: Claude Code plans the spec (Session 1), Codex executes autonomously (Session 2), Claude CLI reviews as the cross-model peer.

## Install

```bash
claude plugin marketplace add https://github.com/stone16/harness-engineering-skills
claude plugin install harness-engineering-skills@stometa
```

Verify:

```bash
claude plugin list | grep harness-engineering-skills
```

## Prerequisites

- **Required**: `git`, `python3`, Claude Code with the [`superpowers`](https://github.com/anthropics/claude-code) plugin installed.
- **Peer reviewer** (one of): [`codex` CLI](https://github.com/openai/codex) or [`gemini` CLI](https://github.com/google-gemini/gemini-cli) — only needed if you use `review-loop` or `harness`'s cross-model review.
- **Optional**: `gh` CLI for PR-scoped review detection.

## Usage

**review-loop** — inside a Claude Code session, once the plugin is installed:

```
/review-loop
```

Variants: `review loop with gemini`, `review loop, max 3 rounds`, `review loop for PR 42`, `review loop for commit abc123`.

**harness** — start a new orchestrated task:

```
harness plan <task-id>
```

Then follow the planning dialogue; `harness` will drive checkpoints through Generator → Evaluator with a cross-model review gate before producing a PR.

## License

Apache-2.0 — see [LICENSE](LICENSE).

## Origin and related

This repo is the public publication surface for a subset of [Stometa](https://github.com/stone16)'s private `stometa-skillset`. Future batches will add more skills as they stabilize. Issues and pull requests are welcome on the [GitHub tracker](https://github.com/stone16/harness-engineering-skills/issues).
