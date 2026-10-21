#!/usr/bin/env node
// afx-token-hygiene.mjs: advisory token-hygiene nudges. Installed by afx-install-claude-hooks.sh. NEVER blocks: it always
// exits 0, fails open on any error, and only ever emits additionalContext. Policy: artifacts/afx-website/docs/TOKEN_EFFICIENCY.md.
//
//   UserPromptSubmit / PreToolUse  transcript file larger than AFX_TH_TRANSCRIPT_BYTES (default 2.5 MB) -> once per session:
//                                  write a hand-off doc and continue in a fresh session.
//   PreToolUse Read                no `limit` on a file over AFX_TH_READ_LINES (default 2000) lines -> use offset/limit or grep.
//   PreToolUse Bash                unbounded output patterns: cat of a big file or a log, tail -f, docker/kubectl logs or
//                                  journalctl without a bound, git log without a count, none of them piped to head/tail/grep/wc.
//   PreToolUse ScheduleWakeup      delay shorter than 1200 s -> no polling; agents notify; use 1200 s+ unless external state moves fast.
//   PreToolUse Bash `sleep N`      5 <= N < 1200 -> same polling nudge.
// Each kind nudges at most MAX_PER_KIND times per session. State: ~/.claude/afx-token-hygiene-state.json (override
// AFX_TOKEN_HYGIENE_STATE), written ONLY by this hook (tmp file + rename), pruned to 40 sessions / 7 days.
// Off switch: AFX_TOKEN_HYGIENE=off. Hook JSON on stdin; context JSON on stdout (same shape as afx-local-hint.mjs).
import { readFileSync, writeFileSync, renameSync, statSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve, isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";

const num = (k, d) => { const n = Number(process.env[k]); return Number.isFinite(n) && n > 0 ? n : d; };
export const MIN_WAKEUP_S = 1200;
export const MAX_PER_KIND = 2;
const MAX_FILE_SCAN = 8 * 1024 * 1024;
const BIG_FILE_BYTES = 200 * 1024;

export const MESSAGES = {
  transcript: (mb) => `AFX token hygiene: this session's transcript is about ${mb} MB. Every turn re-reads it. At a clean point write a hand-off doc (goal, branch, worktree, SHAs, what is left, next commands) to git or memory and continue in a fresh session instead of re-deriving. See TOKEN_EFFICIENCY.md section 3.`,
  read: (n) => `AFX token hygiene: Read without a limit on a file of about ${n} lines. Use offset/limit for the part you need, or grep -n / grep -c first. See TOKEN_EFFICIENCY.md section 4.`,
  bash: (why) => `AFX token hygiene: ${why}. Bound the output (head/tail/grep -c/wc -l, a path range) or run it via scripts/afx-guard/afx-gate-run.sh so only a digest reaches the context. See TOKEN_EFFICIENCY.md section 4.`,
  wake: (s) => `AFX token hygiene: a ${s}s wake-up or sleep is a polling loop. Agents and background jobs notify on completion, and a cache idle for minutes counts in full next turn. Prefer waiting for the notification; if you must schedule, use ${MIN_WAKEUP_S}s or more unless external state really changes faster. See TOKEN_EFFICIENCY.md section 2.`,
};

const BOUND = /\|\s*(head|tail|grep|egrep|rg|wc|sort\s+\|\s*uniq|awk|sed|cut|less)\b|>\s*\S|\bgrep\b|--(tail|lines|since)\b|\s-n\s*\d|--max-count|\s-\d+\b|afx-gate-run|afx-digest/;

/** Returns [kind, text] or null for one tool call. fsx lets tests inject file stats. */
export function checkTool(input, th = {}) {
  const tool = input.tool_name || "";
  const ti = input.tool_input || {};
  if (tool === "ScheduleWakeup") {
    const d = Number(ti.delaySeconds ?? ti.delay_seconds ?? ti.delay);
    if (Number.isFinite(d) && d > 0 && d < MIN_WAKEUP_S) return ["wake", MESSAGES.wake(Math.round(d))];
    return null;
  }
  if (tool === "Read") {
    if (ti.limit != null || !ti.file_path) return null;
    const p = isAbsolute(ti.file_path) ? ti.file_path : resolve(input.cwd || process.cwd(), ti.file_path);
    let st; try { st = statSync(p); } catch { return null; }
    if (!st.isFile() || st.size < 16 * 1024) return null;
    const lim = th.readLines ?? num("AFX_TH_READ_LINES", 2000);
    let lines;
    if (st.size > MAX_FILE_SCAN) lines = Math.round(st.size / 40);
    else { try { const b = readFileSync(p); lines = 0; for (let i = 0; i < b.length; i++) if (b[i] === 10) lines++; } catch { return null; } }
    return lines > lim ? ["read", MESSAGES.read(lines)] : null;
  }
  if (tool === "Bash") {
    const cmd = String(ti.command || "");
    const sl = cmd.match(/(?:^|[;&|\s])sleep\s+(\d+(?:\.\d+)?)\b/);
    if (sl) { const s = Number(sl[1]); if (s >= 5 && s < MIN_WAKEUP_S) return ["wake", MESSAGES.wake(Math.round(s))]; }
    if (BOUND.test(cmd)) return null;
    if (/\b(tail\s+-[a-zA-Z]*[fF])\b/.test(cmd)) return ["bash", MESSAGES.bash("tail -f never ends")];
    if (/\b(docker|kubectl)\s+(compose\s+)?logs\b/.test(cmd) || /\bjournalctl\b/.test(cmd)) return ["bash", MESSAGES.bash("unbounded service log output")];
    if (/\bgit\s+log\b/.test(cmd)) return ["bash", MESSAGES.bash("git log without a count")];
    const cat = cmd.match(/(?:^|[;&|]\s*)cat\s+([^\s|;&<>]+)/);
    if (cat) {
      const f = cat[1].replace(/^["']|["']$/g, "");
      const p = isAbsolute(f) ? f : resolve(input.cwd || process.cwd(), f);
      let size = 0; try { size = statSync(p).size; } catch {}
      if (size > (th.bigBytes ?? BIG_FILE_BYTES) || (/\.(log|out|ndjson|jsonl)$/i.test(f) && size > 20 * 1024)) {
        return ["bash", MESSAGES.bash(`cat of a large file (${Math.round(size / 1024)} KB)`)];
      }
    }
  }
  return null;
}

function transcriptNudge(input) {
  const tp = input.transcript_path;
  if (!tp) return null;
  let size; try { size = statSync(tp).size; } catch { return null; }
  const lim = num("AFX_TH_TRANSCRIPT_BYTES", 2_500_000);
  return size > lim ? ["transcript", MESSAGES.transcript((size / 1e6).toFixed(1))] : null;
}

function loadState(path) { try { const s = JSON.parse(readFileSync(path, "utf8")); return s && typeof s === "object" && s.sessions ? s : { sessions: {} }; } catch { return { sessions: {} }; } }
function saveState(path, s, nowMs) {
  const ids = Object.keys(s.sessions).filter((k) => nowMs - (s.sessions[k].ts || 0) < 7 * 864e5)
    .sort((a, b) => s.sessions[b].ts - s.sessions[a].ts).slice(0, 40);
  const out = { sessions: {} }; for (const k of ids) out.sessions[k] = s.sessions[k];
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(out) + "\n"); renameSync(tmp, path);
}

/** Pure-ish decision: returns {ctx, event} or null; mutates and persists state only when it nudges. */
export function run(input, statePath, nowMs = Date.now()) {
  if (process.env.AFX_TOKEN_HYGIENE === "off") return null;
  const ev = input.hook_event_name || "";
  const found = [];
  if (ev === "UserPromptSubmit" || ev === "PreToolUse") { const t = transcriptNudge(input); if (t) found.push(t); }
  if (ev === "PreToolUse") { const c = checkTool(input); if (c) found.push(c); }
  if (!found.length) return null;
  const sid = String(input.session_id || "nosession");
  const state = loadState(statePath);
  const sess = state.sessions[sid] || { ts: nowMs, nudged: {} };
  const out = [];
  for (const [kind, text] of found) {
    const cap = kind === "transcript" ? 1 : MAX_PER_KIND;
    if ((sess.nudged[kind] || 0) >= cap) continue;
    sess.nudged[kind] = (sess.nudged[kind] || 0) + 1; out.push(text);
  }
  if (!out.length) return null;
  sess.ts = nowMs; state.sessions[sid] = sess;
  try { saveState(statePath, state, nowMs); } catch { /* fail open: nudge anyway */ }
  return { event: ev, ctx: out.join(" ") };
}

function main() {
  try {
    const input = JSON.parse(readFileSync(0, "utf8") || "{}");
    const sp = process.env.AFX_TOKEN_HYGIENE_STATE || join(homedir(), ".claude", "afx-token-hygiene-state.json");
    const r = run(input, sp);
    if (r) process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: r.event, additionalContext: r.ctx } }));
  } catch { /* fail open */ }
  process.exit(0);
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
