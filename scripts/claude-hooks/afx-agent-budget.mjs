#!/usr/bin/env node
// afx-agent-budget.mjs: PreToolUse hook (matcher Agent|Task|Workflow). Token-budget guard for subagent launches.
// Reads ~/.claude/hooks/afx-guard/usage-latest.json (weeklyUsedPct, fiveHourUsedPct, capturedAt) and thresholds from
// machine.conf (budget_warn_pct=50, budget_haiku_only_pct=75, budget_deny_pct=90, budget_stale_s=7200).
//   >= warn      : allow, inject a reminder (use haiku or `afx-task add`, keep reports short)
//   >= haiku-only: deny non-haiku Agent/Task and every Workflow unless the prompt contains [claude-ok]
//   >= deny      : deny everything unless [claude-ok]
//   five-hour window: advisory nudge at >= 80% used (or >= 50% with <= 30 min to reset); see windowNote()
//   stale/missing usage file: warn only (never blocks). Reads, edits and bash are never matched by this hook.
// POOL GATE (overnight contract, lesson 1): every Agent/Task/Workflow launch declares a budget with the line
//   `budget: ~<N>k tokens, <M> min` (model-and-token-budget skill). The launch is DENIED when the sum of budgets already declared in
//   ~/.afx/agents/POOL.json plus this one would exceed 70% of the estimated remaining five-hour window
//   (pool.window_total_tokens x (100 - fiveHourUsedPct)%). An allowed launch writes a 10-minute reservation into POOL.json under a lock
//   (the agent's own first afx-agent-status.sh write replaces it, matched on label = the Agent `description`). No budget line: counted
//   as AFX_DEFAULT_BUDGET (500k) with a reminder. Override: [claude-ok] in the prompt (the owner-approval token this hook already honours).
//   Unlike the weekly levels this also applies at low weekly usage: it protects the shared 5-hour window. Stale usage: not enforced.
// MANUAL WEEKLY (2026-10-23): the owner reads the weekly limit in the Claude app and records it with `afx-agent-status.sh pool set-weekly <pct> <reset ISO>`
//   (~/.afx/agents/WEEKLY.json). While that week has not reset, the HIGHER of snapshot and manual figure drives the weekly levels above, and a stale
//   snapshot no longer switches enforcement off (the week only goes up, so an old manual figure is a lower bound). The five-hour pool gate is unaffected.
// OVERRIDE TOKEN: only the exact literal `[claude-ok]` (square brackets, lowercase) anywhere in the launch input counts; refusals now say so.
// Env overrides for tests: AFX_WEEKLY_FILE, AFX_USAGE_FILE, AFX_MACHINE_CONF, AFX_NOW_S, AFX_AGENTS_DIR (POOL.json lives there), AFX_DEFAULT_BUDGET.
import { readFileSync, writeFileSync, renameSync, mkdirSync, rmSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const DIR = join(homedir(), ".claude/hooks/afx-guard");
const USAGE = process.env.AFX_USAGE_FILE || join(DIR, "usage-latest.json");
const CONF = process.env.AFX_MACHINE_CONF || join(DIR, "machine.conf");

export const OVERRIDE_HELP = "Override (owner-approved launches only): put the exact literal token [claude-ok] (square brackets, lowercase; no other spelling is recognised) in the prompt together with the owner's quoted approval.";

// Manual weekly figure, or null when absent/expired. { pct, resetsAtS }
export function readManualWeekly(nowS, file) {
  try {
    const w = JSON.parse(readFileSync(file, "utf8")); const r = Date.parse(w.resets_at) / 1000;
    if (typeof w.used_pct !== "number" || !(r > nowS)) return null;
    return { pct: w.used_pct, resetsAtS: r };
  } catch { return null; }
}
// The usage object decide() sees: snapshot, with the weekly figure raised to the manual one when that is higher (or the snapshot has none).
export function withManualWeekly(usage, manual) {
  if (!manual) return usage;
  if (usage && typeof usage.weeklyUsedPct === "number" && usage.weeklyUsedPct >= manual.pct) return usage;
  return { ...(usage || {}), weeklyUsedPct: manual.pct, weeklySource: "manual" };
}

export function readConf(text) {
  const num = (k, d) => { const m = text.match(new RegExp(`^${k}=(\\d+)`, "m")); return m ? Number(m[1]) : d; };
  return { warn: num("budget_warn_pct", 50), haiku: num("budget_haiku_only_pct", 75), deny: num("budget_deny_pct", 90), staleS: num("budget_stale_s", 7200) };
}

// Five-hour window nudge (advisory, never denies). Uses fiveHourUsedPct and the optional fiveHourResetsAt (epoch s or ms).
// Elapsed = 5 h - time left; nudges when the window is >= 80% used, or >= 50% used with <= 30 min left.
export function windowNote(usage, nowS) {
  const used = usage.fiveHourUsedPct;
  if (typeof used !== "number") return "";
  const r = usage.fiveHourResetsAt;
  const resetS = typeof r === "number" ? (r > 1e12 ? r / 1000 : r) : null;
  const leftMin = resetS == null ? null : Math.round((resetS - nowS) / 60);
  const hasLeft = leftMin != null && leftMin > 0 && leftMin <= 300;
  const when = hasLeft ? `, resets in ${leftMin} min (${Math.round((300 - leftMin) / 6) / 10} h elapsed)` : "";
  if (used >= 80) return `AFX 5-hour window: ${used}% used${when}. Finish cheap items, write the hand-off, and avoid starting a heavy run that will be cut off.`;
  if (used >= 50 && hasLeft && leftMin <= 30) return `AFX 5-hour window: ${used}% used and resets in ${leftMin} min. Batch what is cheap now; start the heavy work after the reset.`;
  return "";
}

export function decide(input, usage, conf, nowS) {
  const tool = input.tool_name || "";
  if (!/^(Agent|Task|Workflow)$/.test(tool)) return null;
  if (!usage || typeof usage.weeklyUsedPct !== "number") return null;
  const cap = usage.capturedAt > 1e12 ? usage.capturedAt / 1000 : usage.capturedAt;
  const age = nowS - cap;
  const pct = usage.weeklyUsedPct;
  const ti = input.tool_input || {};
  const blob = JSON.stringify(ti);
  const ok = blob.includes("[claude-ok]");
  const model = String(ti.model || "").toLowerCase();
  const isHaiku = tool !== "Workflow" && model.includes("haiku");
  const head = `AFX token budget: weekly Claude usage ${pct}%${usage.weeklySource === "manual" ? " (owner-entered via pool set-weekly)" : ""} (5h ${usage.fiveHourUsedPct ?? "?"}%)`;
  const tips = "Queue mechanical work with `afx-task add <repo> \"<goal>\" --class ...` (local Aider/Ollama, near-zero Claude tokens), use haiku for subagents, and keep reports short.";
  if (Number.isFinite(age) && age > conf.staleS && usage.weeklySource !== "manual") {
    return { ctx: `${head}, but the usage snapshot is ${Math.round(age / 60)} min old (stale): not enforcing. ${tips}` };
  }
  if (pct >= conf.deny && !ok) {
    return { deny: `${head} >= ${conf.deny}%: all subagent/workflow launches are blocked. Do the work inline, queue it with afx-task, or ask the owner. ${OVERRIDE_HELP}` };
  }
  if (pct >= conf.haiku && !ok && !isHaiku) {
    return { deny: `${head} >= ${conf.haiku}%: only haiku subagents are allowed (no Workflow, no sonnet/opus). Relaunch with model: haiku, queue it with afx-task add, or ask the owner. ${OVERRIDE_HELP}` };
  }
  const win = windowNote(usage, nowS);
  if (pct >= conf.warn) return { ctx: `${head} >= ${conf.warn}%. ${tips}${win ? " " + win : ""}` };
  if (win) return { ctx: win };
  return null;
}

// ── pool gate ────────────────────────────────────────────────────────────────
export const CEILING_PCT = 70;
export const DEFAULT_WINDOW_TOKENS = 10_000_000;
const POOL = () => join(process.env.AFX_AGENTS_DIR || join(homedir(), ".afx", "agents"), "POOL.json");
const isoS = (s) => new Date(Math.floor(s) * 1000).toISOString().replace(/\.\d+Z$/, "Z");

// `budget: ~500k tokens, 90 min` (also `budget: 2m tokens`, `budget: 500000 tokens`). Returns { tokens, minutes } or null.
export function parseBudget(text) {
  const m = String(text || "").match(/budget:\s*~?\s*(\d+(?:\.\d+)?)\s*([kKmM])?\s*tokens?(?:\s*,\s*~?(\d+)\s*min)?/i);
  if (!m) return null;
  const mult = /m/i.test(m[2] || "") ? 1_000_000 : /k/i.test(m[2] || "") ? 1000 : 1;
  return { tokens: Math.round(Number(m[1]) * mult), minutes: m[3] ? Number(m[3]) : null };
}
export function declaredSum(pool, nowS) {
  const exp = (a) => (a.source === "reservation" ? Date.parse(a.expires_at) / 1000 > nowS : true);
  return Object.values(pool.agents || {}).filter((a) => a.active && exp(a)).reduce((s, a) => s + (a.declared || 0), 0);
}
// Pure: returns null (not applicable / not enforcing), { deny } or { ctx?, reserve: { label, tokens } }.
export function poolDecision(input, usage, pool, nowS, conf) {
  const tool = input.tool_name || "";
  if (!/^(Agent|Task|Workflow)$/.test(tool)) return null;
  const ti = input.tool_input || {};
  const blob = typeof ti.prompt === "string" ? ti.prompt : JSON.stringify(ti);
  const ok = JSON.stringify(ti).includes("[claude-ok]");
  const parsed = parseBudget(blob) || parseBudget(JSON.stringify(ti));
  const dflt = Number(process.env.AFX_DEFAULT_BUDGET || 500_000);
  const tokens = parsed ? parsed.tokens : dflt;
  const label = String(ti.description || ti.name || tool).slice(0, 80);
  const note = parsed ? "" : `No \`budget: ~<N>k tokens, <M> min\` line in the prompt: counted as ${dflt} tokens. Declare it so the pool is accurate.`;
  const out = { reserve: { label, tokens }, ctx: note };
  if (!usage || typeof usage.fiveHourUsedPct !== "number") return null; // no usage data: nothing to pack against
  const cap = usage.capturedAt > 1e12 ? usage.capturedAt / 1000 : usage.capturedAt;
  if (Number.isFinite(nowS - cap) && nowS - cap > conf.staleS) return out; // stale snapshot: not enforcing (same rule as the weekly levels)
  const total = Number(pool.window_total_tokens) > 0 ? Number(pool.window_total_tokens) : DEFAULT_WINDOW_TOKENS;
  const remaining = Math.floor(total * Math.max(0, 100 - usage.fiveHourUsedPct) / 100);
  const ceiling = Math.floor(remaining * CEILING_PCT / 100);
  const declared = declaredSum(pool, nowS);
  const line = `declared in pool ${declared} + this launch ${tokens} = ${declared + tokens} tokens vs ceiling ${ceiling} (${CEILING_PCT}% of ~${remaining} estimated tokens left in the 5-hour window, ${usage.fiveHourUsedPct}% used)`;
  if (declared + tokens > ceiling && !ok) {
    const r = usage.fiveHourResetsAt; const rs = typeof r === "number" ? (r > 1e12 ? r / 1000 : r) : null;
    const when = rs && rs > nowS ? ` The window resets ${isoS(rs)} (in ${Math.round((rs - nowS) / 60)} min): schedule the launch just after it.` : "";
    return { deny: `AFX pool gate: ${line}. Refused so the fleet cannot exhaust the shared window.${when} Options: shrink this agent's budget, wait for a running agent to finish, free dead agents with the health-reaper script (--apply), recalibrate with afx-agent-status.sh pool set-window N, or ask the owner. ${OVERRIDE_HELP}` };
  }
  const nearly = declared + tokens > ceiling * 0.8;
  out.ctx = [note, ok && declared + tokens > ceiling ? `AFX pool gate overridden by [claude-ok]: ${line}.` : nearly ? `AFX pool: ${line}. Close to the ceiling: prefer finishing running agents first.` : ""].filter(Boolean).join(" ");
  return out;
}
// Read-decide-reserve under a mkdir lock, so 15 simultaneous launches cannot all see the same free budget.
function withPoolLock(fn) {
  const lock = POOL() + ".lock"; let held = false;
  try { mkdirSync(join(lock, ".."), { recursive: true }); } catch {}
  for (let i = 0; i < 80 && !held; i++) {
    try { mkdirSync(lock); held = true; }
    catch { try { if (Date.now() - statSync(lock).mtimeMs > 5000) rmSync(lock, { recursive: true, force: true }); } catch {} Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25); }
  }
  try { return fn(); } finally { if (held) { try { rmSync(lock, { recursive: true, force: true }); } catch {} } }
}
function reservePool(pool, r, nowS) {
  const agents = {};
  for (const [id, a] of Object.entries(pool.agents || {})) if (a.source !== "reservation" || Date.parse(a.expires_at) / 1000 > nowS) agents[id] = a;
  agents[`reserve-${Math.floor(nowS)}-${Math.random().toString(36).slice(2, 6)}`] = { declared: r.tokens, label: r.label, state: "reserved", source: "reservation", active: true, expires_at: isoS(nowS + 600) };
  const next = { schema_version: 1, window_total_tokens: pool.window_total_tokens || DEFAULT_WINDOW_TOKENS, updated_at: isoS(nowS), agents };
  next.declared_sum = declaredSum(next, nowS);
  const f = POOL(); mkdirSync(join(f, ".."), { recursive: true });
  const tmp = `${f}.${process.pid}.tmp`; writeFileSync(tmp, JSON.stringify(next, null, 2) + "\n"); renameSync(tmp, f);
}

function emit(o) { process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", ...o } })); }
function main() {
  let input = {};
  try { input = JSON.parse(readFileSync(0, "utf8") || "{}"); } catch { process.exit(0); }
  let usage = null, conf;
  try { usage = JSON.parse(readFileSync(USAGE, "utf8")); } catch {}
  try { conf = readConf(readFileSync(CONF, "utf8")); } catch { conf = readConf(""); }
  const nowS = process.env.AFX_NOW_S ? Number(process.env.AFX_NOW_S) : Date.now() / 1000;
  const manual = readManualWeekly(nowS, process.env.AFX_WEEKLY_FILE || join(process.env.AFX_AGENTS_DIR || join(homedir(), ".afx", "agents"), "WEEKLY.json"));
  const r = decide(input, withManualWeekly(usage, manual), conf, nowS);
  if (r && r.deny) { emit({ permissionDecision: "deny", permissionDecisionReason: r.deny }); return; }
  let p = null;
  try {
    p = withPoolLock(() => {
      let pool = {}; try { pool = JSON.parse(readFileSync(POOL(), "utf8")); } catch {}
      const d = poolDecision(input, usage, pool, nowS, conf);
      if (d && !d.deny && d.reserve) reservePool(pool, d.reserve, nowS);
      return d;
    });
  } catch { p = null; } // fail open: a ledger problem must never stop the owner's work
  if (p && p.deny) { emit({ permissionDecision: "deny", permissionDecisionReason: p.deny }); return; }
  const ctx = [r && r.ctx, p && p.ctx].filter(Boolean).join(" ");
  if (ctx) emit({ additionalContext: ctx });
}
if (process.argv[1] === fileURLToPath(import.meta.url)) main();
