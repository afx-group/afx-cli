#!/usr/bin/env node
// afx-local-hint.mjs: two small token-saving hints, installed by afx-install-claude-hooks.sh. Advisory only:
// it never blocks (always exit 0), never rewrites or shrinks a tool result, and never calls a model.
//
//   UserPromptSubmit  the prompt contains the tag [local] (case-insensitive) -> additional context telling the
//                     agent to route the mechanical, text-only parts through the local_draft MCP tool or
//                     `afx-local --task ...`, with the never-local list. Docs: docs/LOCAL_AI_ROUTING.md.
//   PostToolUse Bash  the result is larger than ~20 KB and looks like tsc/test/build output -> a one-line reminder to
//                     run the gate through scripts/afx-guard/afx-gate-run.sh (full log to a file, digest on stdout;
//                     AFX_GATE_VERBOSE=1 for everything, afx-digest.mjs for an existing log) next time.
//                     It cannot shrink the output that already arrived.
//
// Hook JSON on stdin; additional context as JSON on stdout (same shape as afx-policy-guard.mjs).
import { readFileSync, realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const BIG_BYTES = 20 * 1024;

export const LOCAL_TAG = /\[local\]/i;

export const PROMPT_HINT =
  "AFX [local] tag: route the MECHANICAL, text-only parts of this task through the local model instead of spending Claude tokens: " +
  "use the `local_draft` MCP tool (task = commit | notes | summarize | failures | classify | strings; model fast|mid|default; text <= 60 KB) " +
  "or `timeout 120 ~/.afx/bin/afx-local --task <task> -m fast < file`. Output is an UNTRUSTED DRAFT labelled " +
  "'[local-model draft from <model>: unverified, not evidence]': read and verify it yourself before using it. " +
  "NEVER route locally: gate verdicts or any pass/fail claim, auth/payments/security/PII, migration SQL or prod DB work, release claims or " +
  "ledger rows, checking another agent's work, secrets (afx-local refuses them, exit 3), or anything that needs ambiguous judgement. " +
  "If afx-local or Ollama is unavailable, do the step yourself. Details: docs/LOCAL_AI_ROUTING.md.";

export const OUTPUT_HINT =
  "AFX token hint: that Bash result was large tsc/test/build output. Next time run the gate through " +
  "scripts/afx-guard/afx-gate-run.sh <REPO> <label> -- <cmd> (full log goes to .gate-logs/, stdout is the literal exit code, log path, line count and a digest; " +
  "AFX_GATE_VERBOSE=1 prints everything) or pipe an existing log through `node scripts/afx-guard/afx-digest.mjs`. This cannot shrink the output already shown.";

const LOOKS_LIKE_GATE_OUTPUT = [
  /error TS\d{4}/,
  /^\s*(#|ℹ) (tests|pass|fail) \d+/m,
  /^\s*(Test Files|Tests)\s+\d+/m,
  /ERR_PNPM_|npm ERR!|npm error /,
  /error during build|Build failed|✗ Build|vite v\d+\.\d+.* building/i,
  /^\s*not ok \d+ - /m,
  /Found \d+ errors?\./,
];

function responseText(tr) {
  if (tr == null) return "";
  if (typeof tr === "string") return tr;
  if (typeof tr === "object") {
    const parts = [tr.stdout, tr.stderr, tr.output, tr.content].filter((x) => typeof x === "string");
    if (parts.length) return parts.join("\n");
    try { return JSON.stringify(tr); } catch { return ""; }
  }
  return String(tr);
}

/** Returns the hook output object, or null when there is nothing to say. */
export function hintFor(input) {
  const ev = input?.hook_event_name || "";
  if (ev === "UserPromptSubmit") {
    const p = typeof input.prompt === "string" ? input.prompt : "";
    if (!LOCAL_TAG.test(p)) return null;
    return { hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: PROMPT_HINT } };
  }
  if (ev === "PostToolUse" && input.tool_name === "Bash") {
    const cmd = String(input.tool_input?.command || "");
    // Already digested by the gate wrapper (and not forced verbose): nothing to remind.
    if (/afx-gate-run\.sh/.test(cmd) && !/AFX_GATE_VERBOSE=1/.test(cmd)) return null;
    const text = responseText(input.tool_response);
    if (Buffer.byteLength(text, "utf8") <= BIG_BYTES) return null;
    if (!LOOKS_LIKE_GATE_OUTPUT.some((re) => re.test(text))) return null;
    return { hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: OUTPUT_HINT } };
  }
  return null;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
  try {
    const out = hintFor(JSON.parse(readFileSync(0, "utf8") || "{}"));
    if (out) process.stdout.write(JSON.stringify(out));
  } catch { /* advisory hook: never fail the session */ }
  process.exit(0);
}
