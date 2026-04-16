#!/usr/bin/env node

/**
 * phase-guard.mjs — Advisory session hook for harness phase enforcement.
 *
 * PreToolUse hook on Bash: detects premature git push / gh pr create / gh pr merge
 * when a harness task is active and phase hasn't reached "pr" or "done".
 *
 * Outputs JSON to stdout per Claude Code hook protocol:
 *   { "decision": "allow", "message": "..." }  — advisory warning, does not block
 *
 * Install in settings.json:
 *   "hooks": {
 *     "PreToolUse": [{
 *       "matcher": "Bash",
 *       "hooks": [{
 *         "type": "command",
 *         "command": "node /path/to/phase-guard.mjs"
 *       }]
 *     }]
 *   }
 */

import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";

// Read hook input from stdin
let input;
try {
  input = JSON.parse(readFileSync("/dev/stdin", "utf8"));
} catch {
  // Not a valid hook invocation — allow silently
  console.log(JSON.stringify({ decision: "allow" }));
  process.exit(0);
}

// Only inspect Bash tool calls
if (input.tool_name !== "Bash") {
  console.log(JSON.stringify({ decision: "allow" }));
  process.exit(0);
}

const command = input.tool_input?.command || "";

// Check if command involves git push or PR operations
const PUSH_PATTERNS = [
  /\bgit\s+push\b/,
  /\bgh\s+pr\s+create\b/,
  /\bgh\s+pr\s+merge\b/,
  /\bgit\s+merge\s+.*main\b/,
  /\bgit\s+merge\s+.*master\b/,
];

const isGitPush = PUSH_PATTERNS.some((p) => p.test(command));

if (!isGitPush) {
  console.log(JSON.stringify({ decision: "allow" }));
  process.exit(0);
}

// Scan for active harness tasks
const harnessDir = ".harness";
if (!existsSync(harnessDir)) {
  console.log(JSON.stringify({ decision: "allow" }));
  process.exit(0);
}

let warning = null;

try {
  const entries = readdirSync(harnessDir, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name === "retro") continue;

    const gsPath = join(harnessDir, entry.name, "git-state.json");
    if (!existsSync(gsPath)) continue;

    const gs = JSON.parse(readFileSync(gsPath, "utf8"));
    const phase = gs.phase || "init";

    // Allow if task is at pr or done phase
    if (phase === "pr" || phase === "done") continue;

    warning = `Harness task "${gs.task_id}" is active (phase: ${phase}). Consider completing review-loop and PR steps before pushing.`;
    break;
  }
} catch {
  // If we can't read harness state, don't block
}

if (warning) {
  console.log(JSON.stringify({ decision: "allow", message: warning }));
} else {
  console.log(JSON.stringify({ decision: "allow" }));
}
