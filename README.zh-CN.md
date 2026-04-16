<p align="center"><a href="README.md">English</a> | <a href="README.zh-CN.md">中文</a></p>

# Harness 工程化技能集

Stometa 对外公开的 Claude Code 精选技能集 —— 一套我们自己每天在用、并按批次对外发布的小而克制的技能。

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Claude Code](https://img.shields.io/badge/Claude_Code-Plugin-blueviolet)](https://claude.ai/claude-code)
[![Peer: Codex](https://img.shields.io/badge/peer-Codex_CLI-74aa9c)](https://github.com/openai/codex)
[![Peer: Gemini](https://img.shields.io/badge/peer-Gemini_CLI-4285F4)](https://github.com/google-gemini/gemini-cli)

## 这个仓库是什么

本仓库是 Stometa 私有仓库 `stometa-skillset` 的**公开**伴随版本。我们在内部使用一套更大的技能集；经过打磨验证的技能会被挑选出来，定期以批次的形式发布到这里。目标是把真正能扛住日常工程工作的工作流分享出来，而不是堆砌一堆原型。

第一批发布两个技能：`review-loop`（日常已经在用）和 `harness`（面向复杂任务的多智能体编排）。两者作为同一个 Claude Code 插件安装。

## 技能清单

### `review-loop`

跨 LLM 的迭代式代码审查。调用一个同行审查者（Codex CLI 或 Gemini CLI）独立审查你的改动，Claude 评估对方的发现，采纳后实现修复并重新提交审查，直到双方对最终代码状态达成一致。审查过程不需要你参与，可以通过 `.review-loop/<session>/summary.md` 查看进展。

### `harness`

面向复杂任务的、基于控制论（cybernetics）的多智能体编排。它把任务驱动成一条 **Planner → Generator → Evaluator → Retro** 流水线，每个 checkpoint 使用全新的子智能体（防漂移），并跨任务持续沉淀复盘经验。推荐流程：Session 1 用 Claude Code 规划 spec，Session 2 用 Codex 自主执行，Claude CLI 作为跨模型同行评审。

## 安装

```bash
claude plugin marketplace add https://github.com/stone16/harness-engineering-skills
claude plugin install harness-engineering-skills@stometa
```

验证安装：

```bash
claude plugin list | grep harness-engineering-skills
```

## 前置条件

- **必需**：`git`、`python3`，以及已安装 [`superpowers`](https://github.com/anthropics/claude-code) 插件的 Claude Code。
- **同行审查者**（任选其一）：[`codex` CLI](https://github.com/openai/codex) 或 [`gemini` CLI](https://github.com/google-gemini/gemini-cli) —— 仅在使用 `review-loop` 或 `harness` 的跨模型审查时需要。
- **可选**：`gh` CLI，用于按 PR 范围检测审查上下文。

## 使用

**review-loop** —— 在 Claude Code 会话中（插件已安装后）：

```
/review-loop
```

变体：`review loop with gemini`、`review loop, max 3 rounds`、`review loop for PR 42`、`review loop for commit abc123`。

**harness** —— 启动一个新的编排任务：

```
harness plan <task-id>
```

按规划对话进行后，`harness` 会驱动各个 checkpoint 在 Generator 和 Evaluator 之间推进，并在产出 PR 之前先经过一次跨模型审查闸门。

## 许可证

Apache-2.0 —— 详见 [LICENSE](LICENSE)。

## 来源与相关项目

本仓库是 [Stometa](https://github.com/stone16) 私有 `stometa-skillset` 部分技能的公开发布窗口。后续批次会在更多技能成熟后继续发布。Issue 和 PR 欢迎提到 [GitHub tracker](https://github.com/stone16/harness-engineering-skills/issues)。
