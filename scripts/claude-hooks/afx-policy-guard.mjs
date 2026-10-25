#!/usr/bin/env node
// afx-policy-guard.mjs — AFX process rules enforced by the Claude Code harness (R21).
// One dispatcher for every hook event; installed by afx-install-claude-hooks.sh into
// ~/.claude/hooks/afx-guard/ and wired in ~/.claude/settings.json. Hooks fire for the main
// session AND every subagent, so these rules don't depend on an agent remembering them.
//
//   PreToolUse  Bash|PowerShell  forbidden git ops, rm -rf on clones, npm/yarn, fake gate results,
//                            .env staging, heavy work without preflight / during a freeze
//   PreToolUse  Agent|Task   R18: explicit model, haiku|sonnet only (higher needs owner approval)
//   PreToolUse  Bash|PowerShell  R19: model calls (claude -p, codex exec) are recorded in SPEND.log; blocking is opt-in (spend_guard=block)
//   PreToolUse  Write|Edit   live secrets in file content
//   PostToolUse Write|Edit   release-claims files → remind the afx-release-claims process
//   Stop                     worktree dirty or unpushed → ask to push before ending (once)
//   SubagentStop             token-ledger line (tokens summed from the agent transcript)
//
// Exit 2 + stderr = block (Claude sees the reason). Owner-approved exception for one Bash
// command: prefix it with AFX_OWNER_OK="<owner's words>" — allowed and logged to
// _readiness/OVERRIDES.log for review. Policy: docs/AFX_WORKING_LOCATIONS.md §6.
import { readFileSync, appendFileSync, existsSync, mkdirSync, readdirSync, unlinkSync, writeFileSync, realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { join, dirname, resolve, basename } from "node:path";

const HOME = homedir();
const GUARD_DIR = dirname(fileURLToPath(import.meta.url));
// One destination per machine. Precedence: env override, then machine.conf `root=`, then the
// historical default. machine.conf is the single place a machine's canonical root is set, so a
// move (e.g. out of ~/Downloads) changes one line and every hook follows.
function confKey(k) { try { return readFileSync(join(GUARD_DIR, "machine.conf"), "utf8").match(new RegExp(`^${k}=(.+)$`, "m"))?.[1]?.trim().replace(/^~/, HOME) || ""; } catch { return ""; } }
// Per-OS default when machine.conf has no root=: the Mac keeps git-only clones flat in _clones; the Lenovo is the
// all-files master and keeps each repo inside its venture's 05_TE folder under the projects root (same as afx-where-am-i.sh).
// The per-OS default comes from the config (clonesRootWindows / clonesRootMac): $AFX_CONFIG, ~/.afx/afx.config.json, then the private
// AFX preset next to this file if present, then the neutral built-in. Read inline (no import) so a missing file can never break the hook.
function cfgGet(k, neutral) {
  const files = [process.env.AFX_CONFIG || join(process.env.HOME || process.env.USERPROFILE || HOME, ".afx", "afx.config.json")];
  if (!process.env.AFX_NO_PRESET) files.push(join(GUARD_DIR, "afx-config.afx.json"), join(GUARD_DIR, "..", "afx-config.afx.json")); // installed flat, or in the hub tree one folder up
  for (const f of files) { try { const v = f && JSON.parse(readFileSync(f, "utf8"))[k]; if (typeof v === "string" && v.trim()) return v; } catch {} }
  return neutral;
}
export const DEFAULT_ROOT = join(HOME, cfgGet(process.platform === "win32" ? "clonesRootWindows" : "clonesRootMac", "~/afx/clones").replace(/^~[\\/]?/, ""));
const CLONES = process.env.AFX_CLONES_ROOT || confKey("root") || DEFAULT_ROOT;
// The folder that holds the clones folder (the "projects root") is protected from rm -rf by name, whatever the install calls it.
export function projectsRootRe(name) {
  if (!/^[\w .-]{2,}$/.test(name || "")) return null;
  return new RegExp("\\brm\\s+(-\\w*r\\w*f|-\\w*f\\w*r|-r\\s+-f|-f\\s+-r)\\b[^|;&]*[/\\s\"']" + name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "(/|\\s|$|[\"'])");
}
const PROJECTS_ROOT_RE = projectsRootRe(basename(dirname(CLONES)));
// machine.conf hub=: this machine's afx-hub clone. Flat layouts default to <root>/afx-holding-group; nested ones (Lenovo) set it.
const HUB = process.env.AFX_HUB || confKey("hub") || join(CLONES, "afx-holding-group");
const AFX = process.env.AFX_ROOT || dirname(CLONES);
const READINESS = join(AFX, "_readiness");
const FREEZE_FILE = join(CLONES, ".caches", "afx-freeze");
const APPROVALS = join(GUARD_DIR, "model-approvals.txt");
// Owner prompts, local only (0600, never in git): lets AFX_OWNER_OK be checked against what the
// owner actually typed. Written ONLY by the UserPromptSubmit hook; tool calls can't touch it.
const OWNER_LOG = join(GUARD_DIR, "owner-prompts.log");

// realpath on argv[1]: through a symlinked path (macOS /var -> /private/var) the old string compare was false and every hook silently allowed everything
// fileURLToPath, not a `file://` string compare: on Windows import.meta.url is file:///C:/... so the old compare was always false
// and the hook silently allowed everything. Compared case-insensitively on win32 (drive letter / folder case).
const IS_MAIN = (() => { try { if (!process.argv[1]) return false; const a = fileURLToPath(import.meta.url); const b = (() => { try { return realpathSync(process.argv[1]); } catch { return process.argv[1]; } })(); return process.platform === "win32" ? a.toLowerCase() === b.toLowerCase() : a === b; } catch { return false; } })();
let input = {};
// Fail closed: a guard that cannot read its input must not wave the call through. Empty input is
// still treated as "{}" (some events send none); only input that is present and not JSON blocks.
if (IS_MAIN) { try { input = JSON.parse(readFileSync(0, "utf8") || "{}"); } catch { process.stderr.write("AFX policy: hook input was not valid JSON, so this call is blocked (fail closed). If this repeats, the owner should check the hook wiring in ~/.claude/settings.json.\n"); process.exit(2); } }
const event = input.hook_event_name || "";
const tool = input.tool_name || "";
const ti = input.tool_input || {};
// Windows hands back C:\\ style paths; every path test in this guard uses forward slashes (normPath is defined further down,
// so this is inline: a const arrow function is not usable before its definition at module load).
const cwd = String(input.cwd || process.cwd()).replace(/\\/g, "/");

const block = (msg) => { process.stderr.write(`AFX policy: ${msg}\n`); process.exit(2); };
const log = (file, line) => { try { mkdirSync(dirname(file), { recursive: true }); appendFileSync(file, line + "\n"); } catch {} };
const stamp = () => new Date().toISOString().replace("T", " ").slice(0, 16);
const git = (dir, ...args) => { try { return execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 8000 }).trim(); } catch { return null; } };

// ── Guard self-protection ───────────────────────────────────────────────────
const GUARD_PATH = "(?:\\.claude/hooks/afx-guard(?:/|\\b)|\\.claude/afx-peer-pause\\b|\\.claude/afx-peer-state\\.json\\b)";
const SETTINGS_PATH = "\\.claude/settings(?:\\.local)?\\.json\\b";
const WRITE_VERB = "(?:sed\\s+-i\\S*|perl\\s+-\\S*i\\S*|rm|mv|cp|truncate|ln|install|rsync|ditto|chmod|chown|touch|tee|dd|unlink|rmdir|mkdir)";
// Returns a block message when a shell command would write to the guard directory, the peer
// control files or ~/.claude/settings.json, or would run the hook installer. Reading stays allowed.
export function guardWrite(c) {
  // The read-only report is allowed: exactly `afx-install-claude-hooks.sh --check` with no other argument.
  const withoutCheck = c.replace(/(?:\b(?:bash|sh)\s+)?[^\s;|&]*afx-install-claude-hooks\.sh\s+--check(?=\s*(?:$|[;|&]|2>&1))/g, "INSTALLER_CHECK");
  // Reading the installer is not running it. Allowed only as ONE simple read-only command with no pipe, redirect, subshell or
  // second command, so nothing can feed the file to a shell (2026-10-13: grep/wc on the installer were being blocked).
  const READ_ONLY_HEAD = /^\s*(?:cat|head|tail|wc|grep|ls|cmp|diff|stat|file|sed\s+-n|git\s+(?:-C\s+\S+\s+)?(?:diff|log|show|blame|add))\s[^|;&$`<>()]*$/;
  const READ_ONLY_FILTER = /^\s*(?:head|tail|wc|cut|sort|uniq|grep|nl)\b[^|;&$`<>()]*$/;
  const segs = c.split("|");
  const readOnly = segs.length <= 4 && READ_ONLY_HEAD.test(segs[0]) && segs.slice(1).every((x) => READ_ONLY_FILTER.test(x)) && !/--output\b/.test(c);
  // Process improvement (owner, 2026-10-23): agents may run the installer to refresh the guard after a change has LANDED on main.
  // Only the bare form, alone (optionally after one `cd`, optionally piped to head/tail). The installer itself refuses a source tree
  // that is dirty or not contained in origin/main, so an agent cannot install an unreviewed guard. --remove, env prefixes, chaining
  // and any other argument stay blocked.
  const soleInstall = /^\s*(?:cd\s+[^\s;|&]+\s*&&\s*)?(?:(?:bash|sh)\s+)?[^\s;|&]*afx-install-claude-hooks\.sh\s*(?:2>&1)?\s*(?:\|\s*(?:tail|head)\s+-\d+\s*)?$/.test(c);
  if (!readOnly && !soleInstall && /afx-install-claude-hooks|afx-hooks-install/.test(withoutCheck)) return "the hook installer runs only bare and alone (`bash scripts/afx-guard/afx-install-claude-hooks.sh`, from a checkout whose change has landed on origin/main); --remove, env prefixes and chaining are the owner's, typed with the ! prefix";
  for (const [path, what] of [[GUARD_PATH, "the installed guard directory (~/.claude/hooks/afx-guard) and the peer control files"], [SETTINGS_PATH, "~/.claude/settings.json"]]) {
    const redirect = new RegExp(`>>?\\s*["']?[^\\s"';|&]*${path}`);
    const verb = new RegExp(`(?:^|[;&|(]\\s*|\\bsudo\\s+|\\bxargs\\s+)${WRITE_VERB}\\b[^|;&]*${path}`);
    if (redirect.test(c) || verb.test(c)) return `${what} are written only by the owner (afx-install-claude-hooks.sh, run by the owner with the ! prefix). Agents may read them, not change them` + (path === SETTINGS_PATH ? ". Use the Edit tool for non-hook settings" : "");
  }
  return null;
}
// Write/Edit tools: anything under the guard directory or the peer control files is blocked;
// ~/.claude/settings.json may be edited, but not its "hooks" block (compared before and after).
export function guardEdit(path, ti = {}, readFile = (f) => readFileSync(f, "utf8")) {
  const p = String(path || "");
  if (new RegExp(GUARD_PATH).test(p + (p.endsWith("/") ? "" : " "))) return "the installed guard directory and the peer control files are written only by the owner (afx-install-claude-hooks.sh with the ! prefix), never by Write/Edit";
  if (!new RegExp(SETTINGS_PATH).test(p)) return null;
  let before = "";
  try { before = readFile(p); } catch { before = ""; }
  let after;
  if (typeof ti.content === "string") after = ti.content;
  else {
    const edits = Array.isArray(ti.edits) ? ti.edits : [{ old_string: ti.old_string, new_string: ti.new_string, replace_all: ti.replace_all }];
    after = before;
    for (const e of edits) {
      if (typeof e.old_string !== "string" || typeof e.new_string !== "string") return "could not tell what this edit to ~/.claude/settings.json changes, so it is blocked (the hooks block is the owner's)";
      after = e.replace_all ? after.split(e.old_string).join(e.new_string) : after.replace(e.old_string, () => e.new_string);
    }
  }
  const hooksOf = (t) => { if (!t.trim()) return "null"; return JSON.stringify(JSON.parse(t).hooks ?? null); };
  try { if (hooksOf(before) !== hooksOf(after)) return "the hooks block of ~/.claude/settings.json is changed only by the owner (afx-install-claude-hooks.sh with the ! prefix). Other settings may be edited"; }
  catch { return "this edit would leave ~/.claude/settings.json unparsable, or it is unparsable now, so a change to it is blocked (the hooks block is the owner's)"; }
  return null;
}

// ── Scratch (owner 2026-10-22): repo code is not copied into the shared /tmp ───────────────
// The shared /tmp is for logs, text output and screenshots. A source file written there is a copy of code that has a home in a repo:
// it goes stale, nobody finds it again, and it gets re-merged by hand (2026-10-21: /private/tmp held copies of repo files, merge
// scratch and test copies). Write the file in the worktree instead. The session scratchpad (/tmp/claude-<uid>/...) is not covered:
// it holds the session's own helper scripts.
const SHARED_TMP = /^(?:\/private)?\/tmp\/(?!claude-\d+\/)|^[a-z]:\/tmp\//i;
const SOURCE_FILE = /\.(?:ts|tsx|js|jsx|mjs|cjs|sh|bash|py|swift|kt|dart|json|ya?ml|md|html?|css|sql)$/i;
export const SCRATCH_MSG = "scratch: repo code is not copied into the shared /tmp (it goes stale and is lost). Write the file in your worktree (<repo>/.claude/worktrees/<name>). /tmp takes logs, text output and screenshots only";
// Write/Edit: a source file whose path is under the shared /tmp.
export function scratchCopy(path) {
  const p = String(path || "").replace(/\\/g, "/");
  return SHARED_TMP.test(p) && SOURCE_FILE.test(p) ? SCRATCH_MSG : null;
}
// Shell: a source file under the shared /tmp as the DESTINATION of cp/mv/install/ditto, a tee, or a > / >> redirect. Copying a file
// out of /tmp into a repo is not blocked.
export function scratchCopyBash(c) {
  const cmd = String(c || "");
  const dests = [];
  for (const m of cmd.matchAll(/(?:>>?|\btee\s+(?:-a\s+)?)\s*["']?([^\s"';|&<>]+)/g)) dests.push(m[1]);
  for (const seg of cmd.split(/[;&|]/)) {
    if (/^\s*(?:cp|mv|install|ditto)\b/.test(seg)) { const parts = seg.trim().split(/\s+/).filter((t) => !t.startsWith("-")); if (parts.length > 2) dests.push(parts[parts.length - 1].replace(/["']/g, "")); }
  }
  return dests.some((d) => SHARED_TMP.test(d) && SOURCE_FILE.test(d)) ? SCRATCH_MSG : null;
}

// ── R19: model-call spend ───────────────────────────────────────────────────
// Real model calls (claude -p / --print, codex exec) spend the owner's usage, and nothing saw them: R18 only covers the Agent tool and
// the budget hook only Agent|Task|Workflow, so a shell loop of `claude -p` ran past every guard (2026-10-19: 48 runs across three models
// were started to turn n=1 into a rate; the owner stopped it after 4). The real question is whether the work is worth doing, which a
// pattern cannot judge, and the owner must never have to type a command to keep work going. So by default R19 only RECORDS: every
// command that starts model calls (a direct call, a loop, or a script that makes them) is logged to _readiness/SPEND.log with its
// shape (bounded call, loop, script), and nothing is blocked. The owner can opt into blocking with `spend_guard=block` in machine.conf
// (or AFX_SPEND_GUARD=block): then an unbounded call needs a spend approval, as described below.
const SPEND_APPROVALS = join(GUARD_DIR, "spend-approvals.txt");
// "log" (default: record, never block) or "block" (opt-in). machine.conf `spend_guard=block`, or the AFX_SPEND_GUARD env for tests.
export function spendMode() {
  const env = (process.env.AFX_SPEND_GUARD || "").toLowerCase();
  if (env === "block" || env === "log") return env;
  try { return readFileSync(join(GUARD_DIR, "machine.conf"), "utf8").match(/^spend_guard=(\w+)/m)?.[1]?.toLowerCase() === "block" ? "block" : "log"; } catch { return "log"; }
}
const CALL_AT = "(?:^[ \\t]*|[;&|(={]\\s*)";
const SPEND_CLAUDE = new RegExp(`${CALL_AT}(?:call\\s+)?["']?(?:[^\\s"';|&]*[\\\\/])?claude(?:\\.exe|\\.cmd)?["']?\\s+(?:[^\\n;&|]*?\\s)?(?:-p|--print)(?=\\s|$)`, "im");
const SPEND_CODEX = new RegExp(`${CALL_AT}["']?(?:[^\\s"';|&]*[\\\\/])?codex(?:\\.exe|\\.cmd)?["']?\\s+exec\\b`, "im");
// Wrappers put the call after other words (`xargs -I{} claude -p`, `timeout 60 claude -p`, `nohup claude -p`), so the boundary above misses them.
const SPEND_VIA = /\b(?:xargs|parallel|timeout|nohup|env|sudo|time|start|do|then|else)\b[^\n;&|]*?\s["']?(?:[^\s"';|&]*[\\/])?claude(?:\.exe|\.cmd)?["']?\s+(?:[^\n;&|]*?\s)?(?:-p|--print)(?=\s|$)/im;
export function spendCall(t) { return SPEND_CLAUDE.test(t) || SPEND_CODEX.test(t) || SPEND_VIA.test(t); }
const LOOPY = /\b(?:for|foreach|while|until)\b|ForEach-Object|\b\d+\.\.\$?\w+|\bseq\s|\bxargs\b|\bparallel\b/i;
const SCRIPT_REF = /[^\s"'&;|()<>`]+\.(?:ps1|sh|bash|py|mjs|cjs|js|cmd|bat)\b/gi;
const stripComments = (t) => t.split("\n").filter((l) => !/^\s*(#|\/\/)/.test(l)).join("\n");
function expandPath(p, dir) {
  let s = p.replace(/\$env:USERPROFILE|\$\{?HOME\}?|%USERPROFILE%|\$USERPROFILE/gi, HOME.replace(/\\/g, "/")).replace(/^~(?=[\\/])/, HOME.replace(/\\/g, "/"));
  if (process.platform === "win32") s = s.replace(/^\/([a-zA-Z])\//, "$1:/");
  return /^([a-zA-Z]:)?[\\/]/.test(s) ? s : resolve(dir, s);
}
const defaultSpendIo = {
  read: (f) => { const t = readFileSync(f, "utf8"); return t.length > 262144 ? t.slice(0, 262144) : t; },
  exists: (f) => existsSync(f),
};
export const SPEND_BLOCK = "R19 (strict mode, opted in by the owner in machine.conf): this command starts real model calls without a bounded shape. Either bound it (`--model haiku|sonnet` and a `--max-turns` cap, no loop, not inside a script) or ask the owner, who can approve by typing `approve-spend <N>d <reason>`. Whether it is worth doing is the real question: is there a cheaper way (a deterministic test, one run, data from real sessions) to answer the same thing?";
// Returns null (not a spend command), { note } (allowed; logged) or { block }.
export function spendCheck(c, dir = cwd, io = defaultSpendIo, approvedNow = () => { try { return approvalState(readFileSync(SPEND_APPROVALS, "utf8"), "spend"); } catch { return false; } }) {
  const direct = spendCall(c);
  let script = null;
  for (const ref of (c.match(SCRIPT_REF) || []).filter((r) => executesRef(c, r)).slice(0, 6)) {
    try {
      const f = expandPath(ref, dir);
      if (io.exists(f) && spendCall(stripComments(io.read(f)))) { script = ref; break; }
    } catch { /* unreadable: judged by the command text alone */ }
  }
  if (!direct && !script) return null;
  const loop = direct && LOOPY.test(c);
  const model = (c.match(/--model(?:=|\s+)["']?([A-Za-z0-9.\-]+)/) || [])[1] || "";
  const turns = Number((c.match(/--max-turns(?:=|\s+)(\d+)/) || [])[1] || 0);
  const bounded = direct && !script && !loop && /^(haiku|sonnet)$/i.test(model) && turns >= 1 && turns <= 30;
  if (bounded) return { note: `one bounded call (${model}, max-turns ${turns})` };
  if (approvedNow()) return { note: `approved spend: ${script ? "script " + script : loop ? "loop" : "call"}` };
  return { block: SPEND_BLOCK + (script ? ` (the script ${script} makes model calls.)` : loop ? " (this looks like a loop of model calls.)" : " (add --model and --max-turns.)") };
}
// Usage thresholds and the loop ceiling (owner review 2026-10-19). The owner already set the weekly lines for subagents in machine.conf
// (budget_warn_pct 50, budget_deny_pct 90) and afx-agent-budget.mjs reads usage-latest.json; model calls started from the shell follow the
// same lines: free below the warn line, "prefer haiku" (recorded, never blocked) between, paused above the deny line unless the command
// carries [claude-ok]. Separately, a LOOP of model calls whose size is unknown or above spend_loop_max (default 10) must state its size
// with [loop-ok:<N>] (or AFX_LOOP_OK=<N>): nobody approves anything, the agent writes down the real size, and it is recorded.
const usageFile = () => process.env.AFX_USAGE_FILE || join(GUARD_DIR, "usage-latest.json");
export function spendConf(text = "") {
  const num = (k, d) => { const m = text.match(new RegExp(`^${k}=(\\d+)`, "m")); return m ? Number(m[1]) : d; };
  return { warn: num("budget_warn_pct", 50), deny: num("budget_deny_pct", 90), staleS: num("budget_stale_s", 7200), loopMax: num("spend_loop_max", 10) };
}
function readSpendConf() { try { return spendConf(readFileSync(join(GUARD_DIR, "machine.conf"), "utf8")); } catch { return spendConf(""); } }
export function usageLevel(usage, conf, nowS) {
  if (!usage || typeof usage.weeklyUsedPct !== "number") return { level: "free", pct: null };
  const pct = usage.weeklyUsedPct;
  const cap = usage.capturedAt > 1e12 ? usage.capturedAt / 1000 : usage.capturedAt;
  if (Number.isFinite(cap) && nowS - cap > conf.staleS) return { level: "free", pct, stale: true };
  return { level: pct >= conf.deny ? "pause" : pct >= conf.warn ? "prefer-haiku" : "free", pct };
}
function readUsage() { try { return JSON.parse(readFileSync(usageFile(), "utf8")); } catch { return null; } }
const nowSeconds = () => Number(process.env.AFX_NOW_S) || Date.now() / 1000;
// Size of a loop of calls found in text: 0 = no loop, a number = counted from literals, null = a loop whose size cannot be told
// (a variable-bound range, an unknown list, or a parameter the text does not give).
export function loopSize(t) {
  if (!LOOPY.test(t)) return 0;
  if (/\.\.\s*\$|\bin\s+\$|\bin\s+@\(|\$\{?\w+\}?\s*\)\s*\{?\s*$/m.test(t) && !/\b\d+\.\.\d+\b/.test(t)) return null;
  const sizes = [];
  for (const m of t.matchAll(/\b(\d+)\.\.(\d+)\b/g)) sizes.push(Math.abs(Number(m[2]) - Number(m[1])) + 1);
  for (const m of t.matchAll(/\bseq\s+(?:\d+\s+)?(\d+)\b/g)) sizes.push(Number(m[1]));
  for (const m of t.matchAll(/\bfor\s+\w+\s+in\s+([^;\n$*(]*?)\s*(?:;|\n)\s*do\b/g)) sizes.push(m[1].trim().split(/\s+/).filter(Boolean).length);
  for (const m of t.matchAll(/(?:-Reps|--reps|--count|--runs|-n)\s+(\d+)/gi)) sizes.push(Number(m[1]));
  if (!sizes.length || /\.\.\s*\$|\bin\s+\$/.test(t)) return null;
  return sizes.reduce((a, b) => a * b, 1);
}
// In a script file, a loop counts only when the model call is INSIDE it: walk up from each call line through the lines with less
// indentation (its enclosing blocks) and look for loop headers. 0 = no call sits in a loop (for example a loop that only parses the
// output), a number = counted from the headers' literals, null = the enclosing loops' size cannot be told.
export function scriptLoopSize(text) {
  const lines = text.split("\n");
  const indent = (l) => l.match(/^[ \t]*/)[0].replace(/\t/g, "    ").length;
  const headers = [];
  for (let i = 0; i < lines.length; i++) {
    if (!lines[i].trim() || !spendCall(lines[i])) continue;
    let ind = indent(lines[i]);
    for (let j = i - 1; j >= 0 && ind > 0; j--) {
      if (!lines[j].trim() || indent(lines[j]) >= ind) continue;
      ind = indent(lines[j]);
      if (LOOPY.test(lines[j])) headers.push(lines[j]);
    }
    if (!headers.length && LOOPY.test(lines[i])) headers.push(lines[i]); // a one-line loop: `for ...; do claude -p ...; done`
  }
  if (!headers.length) return 0;
  return loopSize(headers.join("\n"));
}
export const declaredLoop = (c) => { const m = c.match(/\[loop-ok:(\d+)\]|AFX_LOOP_OK=(\d+)|--loop-ok[= ](\d+)/); return m ? Number(m[1] || m[2] || m[3]) : 0; };
// A script named in the command only matters for R19 when the command RUNS it. Reading it (grep, sed -n, cat, diff, git add) does not
// start model calls even if the file's text mentions a model call (false positive 2026-10-23: grepping the guard's own source).
const RUNS = "(?:bash|sh|zsh|node|python3?|tsx|pwsh|powershell|source|exec|nohup|xargs|time|env|sudo|timeout\\s+\\d+)";
export function executesRef(c, ref) {
  const esc = ref.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  c = c.replace(/\b(?:node\s+--check|node\s+-c|(?:ba)?sh\s+-n)\s+\S+/g, " "); // a syntax check parses the file, it does not run it
  return new RegExp(`(?:^[ \\t]*|[;&|(]\\s*|\\b${RUNS}\\s+(?:-\\S+\\s+)*)["']?${esc}(?![\\w.-])`, "im").test(c);
}
// null (no model calls in a loop), { loop } (fine: small, or declared) or { loopBlock }.
export function loopCheck(c, dir = cwd, io = defaultSpendIo, max = 10) {
  const direct = spendCall(c);
  let scriptText = null;
  for (const ref of (c.match(SCRIPT_REF) || []).filter((r) => executesRef(c, r)).slice(0, 6)) {
    try { const f = expandPath(ref, dir); if (io.exists(f)) { const t = stripComments(io.read(f)); if (spendCall(t)) { scriptText = t; break; } } } catch { /* unreadable */ }
  }
  if (!direct && scriptText === null) return null;
  const sizes = [];
  if (direct) sizes.push(loopSize(c));
  if (scriptText !== null) sizes.push(scriptLoopSize(scriptText));
  const n = sizes.some((x) => x === null) ? null : Math.max(0, ...sizes);
  if (n === 0) return null;
  if (n !== null && n <= max) return { loop: n };
  const decl = declaredLoop(c);
  if (decl && (n === null || decl >= n)) return { loop: decl, declared: true };
  return { loopBlock: `R19: this runs a loop of model calls whose size is ${n === null ? "not known" : `${n}, over the ceiling of ${max}`}. If a loop really is the best way to answer the question, state the size you intend by adding [loop-ok:<N>] to the command: nobody has to approve it, it just makes the size visible and recorded. First check that something cheaper (a deterministic test, one run, data from real sessions) would not answer the same thing.` };
}
// Parses the owner's prompt: `approve-spend [<N>d|standing] [reason…]` or `revoke-spend [reason…]`, only at the very start.
export function parseSpendPrompt(prompt, day = today()) {
  const m = String(prompt || "").match(/^\/?(approve-spend|revoke-spend)(?:\s+(\d{1,3}d|standing))?\s*([\s\S]*)$/i);
  if (!m) return null;
  const [, verb, span, reason] = m;
  const why = (reason || "").trim().split("\n")[0].slice(0, 200) || "(no reason given)";
  if (verb.toLowerCase() === "revoke-spend") return { line: `revoke spend ${day} owner: ${why}`, msg: "revoked spend approval" };
  let until = "";
  if (span && span.toLowerCase() === "standing") until = " until=standing";
  else if (span) {
    const d = new Date(`${day}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + Math.max(1, parseInt(span, 10)) - 1);
    until = ` until=${d.toISOString().slice(0, 10)}`;
  }
  return { line: `spend ${day}${until} owner: ${why}`, msg: `approved spend${until ? ` (${until.trim()})` : " (today only)"}` };
}
const BASH_LIKE = /^(Bash|PowerShell)$/;
export const isShellTool = (t) => BASH_LIKE.test(t || "");

// ── Bash ────────────────────────────────────────────────────────────────────
// Package manager of the project at `dir`: the nearest afx.config.json up the tree (`packageManager`), else pnpm (the AFX default).
// Read inline, never throws: a missing or broken file can not break the hook.
const PMS = ["npm", "pnpm", "yarn", "bun"];
export function projectPm(dir) {
  let d = resolve(dir || ".");
  for (let i = 0; i < 12; i++) {
    const f = join(d, "afx.config.json");
    if (existsSync(f)) { try { const v = JSON.parse(readFileSync(f, "utf8")).packageManager; if (PMS.includes(v)) return v; } catch {} return "pnpm"; }
    const up = dirname(d);
    if (up === d) break;
    d = up;
  }
  return "pnpm";
}
const PM_INSTALL = {
  npm: /(^|[;&|]\s*)npm\s+(install|i|ci|add)\b/,
  yarn: /(^|[;&|]\s*)yarn(\s+(install|add)\b|\s*$)/,
  pnpm: /(^|[;&|]\s*)pnpm\s+(install|i|add)\b/,
};

export function checkBash(cmd, dir = cwd) {
  const c = stripMessageArgs(stripDataHeredocs(cmd)).replace(/\\\n/g, " ");
  // R18: only the owner grants model approvals (their typed prompt or a `!` command, neither of
  // which is a tool call). No AFX_OWNER_OK escape: an agent must never approve its own model.
  if (/model-approvals\.txt|afx-approve-model/.test(c)) return { block: "R18: model approvals are the owner's to grant: ask them to type `approve-model <model> <N>d|standing <reason>` in the prompt" };
  // The guards protect themselves (2026-10-08): the installed hook scripts, the approval ledgers and
  // the peer controls are written only by the owner (afx-install-claude-hooks.sh or a `!` command,
  // neither of which is a tool call). An agent overwrote the installed guard with a plain `cp`
  // twice that day and nothing stopped it. No AFX_OWNER_OK escape, same as model approvals.
  const g = guardWrite(c);
  if (g) return { block: g };
  // R19: spend approvals are the owner's, like model approvals; then the spend check itself (no AFX_OWNER_OK escape either).
  if (/spend-approvals\.txt|afx-approve-spend/.test(c)) return { block: "R19: the spend approval file is the owner's (used only in the opt-in strict mode); it is not written by tool calls" };
  const sp = spendCheck(c, dir);
  if (sp) {
    const conf = readSpendConf();
    const lvl = usageLevel(readUsage(), conf, nowSeconds());
    if (lvl.level === "pause" && !c.includes("[claude-ok]")) return { block: `R19: weekly usage is ${lvl.pct}%, past the owner's pause line (${conf.deny}%), so model calls from the shell wait until the window resets or the owner asks for this run (then add [claude-ok] to the command). Nothing needs typing to keep other work going.` };
    const lp = loopCheck(c, dir, defaultSpendIo, conf.loopMax);
    if (lp?.loopBlock) return { block: lp.loopBlock };
    if (sp.block && spendMode() === "block") return { block: sp.block };
    const what = sp.block ? "UNBOUNDED (recorded, not blocked)" : sp.note;
    const extra = `${lp?.loop ? ` loop=${lp.loop}${lp.declared ? " (declared)" : ""}` : ""} usage=${lvl.pct ?? "?"}%${lvl.level === "prefer-haiku" ? " prefer-haiku" : ""}`;
    log(join(READINESS, "SPEND.log"), `${stamp()} ${what}${extra} :: ${cwd} :: ${String(c).slice(0, 160).replace(/\s+/g, " ")}`);
  }
  const ov = c.match(/^\s*AFX_OWNER_OK=("[^"]+"|'[^']+')/);
  if (ov) {
    const words = ov[1].slice(1, -1);
    return ownerSaid(words) ? { override: true }
      : { block: `AFX_OWNER_OK must quote words the owner actually typed in the last 24h ("${words.slice(0, 60)}" isn't in the owner prompt log). Ask the owner in chat` };
  }
  const PROT = "(owner-prompts\\.log|model-approvals\\.txt|spend-approvals\\.txt|replit-ops-ledger\\.jsonl|prod-approvals)";
  if (new RegExp(`>>?\\s*["']?\\S*${PROT}|\\btee\\s+(-a\\s+)?["']?\\S*${PROT}|\\b(sed\\s+-i\\S*|rm|mv|cp|truncate|ln)\\b[^|;&]*${PROT}`).test(c)) {
    return { block: "the owner prompt log and model approvals are written only by the owner's own prompts" };
  }
  // Commands that only run on a remote host are judged there, not here.
  // Remote-dispatched commands are judged on the remote host, so the heavy-work block must not
  // fire on them. Allow benign prefixes before the dispatcher — a `cd <dir> &&` or leading env
  // assignments — so a gate run from a subdirectory (e.g. `cd artifacts/x &&
  // ../../scripts/afx-guard/afx-remote-gate.sh HUB b 'tsc'`) is still recognised. A real local
  // command before it (e.g. `pnpm install && afx-remote-gate.sh …`) is NOT a benign prefix and
  // still blocks, because `pnpm install` is local heavy work.
  const remoteOnly = /^\s*((?:cd\s+(?:"[^"]*"|'[^']*'|\S+)\s*&&\s*|[A-Za-z_]\w*=(?:"[^"]*"|'[^']*'|\S*)\s+)*)(ssh|\S*afx-remote-gate\.sh)\b/.test(c);
  // Ad-hoc ssh to a Replit workspace: read-only probes are fine; anything that writes, runs code or touches
  // git state must go through afx-remote-ops.sh / afx-remote-gate.sh (ledger, locks, dry-run, masking).
  const adhocSsh = /(^|[;&|]\s*|&&\s*)(\S*\/)?ssh\b[^\n]*?(replit\.dev|\.ssh\/replit)/m.test(c);
  if (adhocSsh && !allowlistedProbe(c)) {
    const w = adhocSshWrite(c);
    if (w) return { block: `ad-hoc ssh to a Replit workspace may not ${w}. Use scripts/afx-guard/afx-remote-ops.sh <venture> <verb> (status|sync|install|migrate-plan|migrate-apply|test|restart|health|logs|align-main; mutating verbs are dry-run until --apply) afx-remote-ops.sh <venture> probe <name> for a named read-only probe (list: registry/remote-probes.txt), or afx-remote-gate.sh for gates. See docs/REPLIT_SSH_OPS.md` };
  }
  const rules = [
    [/\bgit\b[^|;&]*\bpush\b[^|;&]*(\s--force(-with-lease)?\b|\s-f\b|\s\+\S+)/, "force-push needs the owner's explicit OK (push a new branch instead)"],
    [/\bgit\b[^|;&]*\breset\b[^|;&]*--hard\b/, "git reset --hard needs the owner's explicit OK (it discards work)"],
    [/\bgit\b[^|;&]*\bclean\b[^|;&]*\s-\w*f/, "git clean -f needs the owner's explicit OK (it deletes untracked work)"],
    [/\bgit\b[^|;&]*\b(checkout|restore)\b[^|;&]*\s(--\s+)?\.(\s|$)/, "git checkout/restore of '.' needs the owner's explicit OK (it discards all local changes). To clear generated churn from a leftover worktree whose commits are on GitHub, run `scripts/afx-guard/afx-land.sh --cleanup --discard-churn`: it saves a patch first and refuses real work"],
    [/\bgit\b[^|;&]*\bstash\s+(drop|clear)\b/, "git stash drop/clear needs the owner's explicit OK (other sessions share the stash stack)"],
    [/\bgit\s+(-C\s+("[^"]+"|\S+)\s+)?(gc|prune)\b/, "git gc/prune needs the owner's explicit OK"],
    [/\bgit\s+(clone|init)\b/, "git clone/init needs the owner's explicit OK (one clone per repo, in _clones)"],
    // Ported 2026-10-20 from the Lenovo's legacy per-machine guard hook (retired into this guard, which has
    // the AFX_OWNER_OK path that one lacked). Its `git worktree prune` block is not ported: hub cleanup prints and runs it.
    [/\bgit\b[^|;&]*\bpush\b[^|;&]*\s(\S*:(refs\/heads\/)?(main|master)|(main|master))(\s|$)/, "main changes only through a PR landed with afx-land.sh, never a direct push"],
    [/\bgit\b[^|;&]*\badd\s+(-A|--all|\.)(\s|$)/, "stage explicit paths, never `git add -A` / `git add .` (sibling worktrees and archives get committed)"],
    [/--no-verify\b/, "never skip hooks (--no-verify)"],
    [/\bgit\b[^|;&]*\badd\b[^|;&]*(^|\s|\/)\.env(?:\.(?!(?:example|sample|template)(?:\s|$))\w+)?(\s|$)/, "never stage a .env file (template files .env.example, .env.sample and .env.template are allowed)"],
    [/\brm\s+(-\w*r\w*f|-\w*f\w*r|-r\s+-f|-f\s+-r)\b[^|;&]*(_clones|\.claude\/worktrees|\s~\/?(\s|$)|\s\$HOME\/?(\s|$))/, "never rm -rf a clone/worktree/projects-root path: prove it's on GitHub, then move it to the Trash"],
    ...(PROJECTS_ROOT_RE ? [[PROJECTS_ROOT_RE, "never rm -rf a clone/worktree/projects-root path: prove it's on GitHub, then move it to the Trash"]] : []),
    // Only match the keyword at a COMMAND position — statement start, after ;&|, after a path
    // separator (scripts/gate.sh, ./verify.sh), or after a runner (pnpm/npm/yarn/npx/make/bash/sh/
    // node [run]) — so an incidental keyword in a branch name or flag (e.g. `-b remote-gate-x`, a
    // path like `foo-test-bar`) followed by an unrelated `&& echo OK` is NOT a false positive.
    [/(?:^|[;&|/]\s*|\b(?:pnpm|npm|yarn|npx|make|bash|sh|node)(?:\s+run)?\s+)(test|tests|typecheck|tsc|build|verify|gate|lint|jest|vitest)\b[^|;]*&&\s*echo\s+["']?(OK|PASS(ED)?|SUCCESS|GREEN)/i, "don't mask exit codes with `&& echo PASSED`; print the real exit code (echo \"exit=$?\")"],
    // Push-output masking (sync-guard a): block only patterns that truly SWALLOW a push failure
    // — `|| true` / `|| :` (force exit 0), and a bare `2>/dev/null` / `&>/dev/null` /
    // `>/dev/null 2>&1` NOT followed by an outcome check. A redirection followed by `&&`/`||`
    // (e.g. `2>/dev/null && echo PUSHED || echo FAILED`, afx-preserve-all's pattern) surfaces the
    // outcome and is allowed, as are `|| echo "push=$?"` (our recommended pattern) and `| tail`.
    // The Stop hook backstops any push failure regardless (unpushed commits are flagged).
    [/\bgit\s+push\b[^;&\n]*(\|\|\s*(true(?![a-z])|:)|(2>\s*\/dev\/null|&>\s*\/dev\/null|>\s*\/dev\/null\s+2>&1)(?!\s*(&&|\|\|)))/, "don't silently swallow a git push failure (|| true, || :, or a bare 2>/dev/null / &>/dev/null / >/dev/null 2>&1 with no outcome check): the branch is lost. Surface it — `git push … || echo \"push=$?\"` or `… && echo PUSHED || echo FAILED` are both fine."],
  ];
  if (!remoteOnly || adhocSsh) {
    for (const [re, why] of rules) if (re.test(c)) return { block: why };
    const pm = projectPm(dir);
    for (const m of Object.keys(PM_INSTALL)) {
      if (m !== pm && PM_INSTALL[m].test(c)) return { block: `this project uses ${pm} only (${m} creates duplicate caches and lockfiles)${pm === "pnpm" ? "; AFX is pnpm-only" : ""}` };
    }
    const del = projectsRecursiveDelete(c);
    if (del) return { block: del };
    const wt = c.match(/\bgit\b[^|;&]*\bworktree\s+add\s+(?:-[bB]\s+\S+\s+|--?[a-zA-Z-]+\s+)*("[^"]+"|\S+)/);
    if (wt) {
      // Resolve "$VAR"/${VAR} from an assignment earlier in the same command (reported by
      // reported by a peer session: `WT=…/.claude/worktrees/x; git worktree add "$WT"` was wrongly blocked).
      // A variable we can't see is allowed: the sweep's fragment audit catches stray worktrees.
      let path = wt[1].replace(/^["']|["']$/g, "");
      const v = path.match(/^\$\{?(\w+)\}?(.*)$/);
      if (v) {
        const assign = c.match(new RegExp(`(?:^|[\\s;&])${v[1]}=("[^"]*"|'[^']*'|[^\\s;&|]+)`));
        path = assign ? assign[1].replace(/^["']|["']$/g, "") + v[2] : null;
      }
      if (path !== null && !/\.claude\/worktrees\//.test(path)) return { block: "worktrees go under <repo>/.claude/worktrees/<name> only" };
    }
  }
  // Heavy local work: preflight + freeze (R17). Remote gates are exempt.
  const heavy = /(^|[;&|]\s*|\s)(pnpm\s+(install|i|add|(run\s+)?(typecheck|build|test))\b|tsc\b(?!\s+--version)|xcodebuild\b|pod\s+install\b|(npx\s+)?expo\s+(export|prebuild|run:ios|run:android)\b|eas\s+build\b)/;
  const pmName = projectPm(dir);
  const heavyRe = pmName === "pnpm" ? heavy : new RegExp(heavy.source.replace("pnpm\\s+", `(?:pnpm|${pmName})\\s+`));
  if (!remoteOnly && heavyRe.test(c)) {
    // Per-machine policy (~/.claude/hooks/afx-guard/machine.conf, written by afx-new-mac-setup.sh):
    //   heavy_local=ship-only  (default on macOS: the 8 GB Mac is reserved for Xcode ships)
    //   heavy_local=preflight  (e.g. the 64 GB MacBook Pro: allowed when afx-preflight.sh passes)
    //   heavy_local=none       (retired from builds: always blocked; remote gates still allowed)
    const isMac = (process.env.AFX_OS || process.platform) === "darwin";
    let heavyPolicy = process.env.AFX_HEAVY_LOCAL || "";
    if (!heavyPolicy) { try { heavyPolicy = readFileSync(join(GUARD_DIR, "machine.conf"), "utf8").match(/^heavy_local=(\S+)/m)?.[1] || ""; } catch {} }
    if (!heavyPolicy) heavyPolicy = isMac ? "ship-only" : "preflight";
    // Slot-wrapped = the SAME command acquires a gate slot (afx_gate_acquire, or afx-gate-run.sh). Slots bound the
    // concurrency (AFX_GATE_SLOTS, default 3), so a wrapped job may pass preflight at a higher load average.
    const slotWrapped = /afx_gate_acquire|afx-gate-run\.sh/.test(c);
    //   heavy_local=none        retired from builds: always blocked (remote gates still allowed)
    //   heavy_local=ship-only   (default on a Mac with no machine.conf: the 8 GB Mac is for Xcode ships)
    //   heavy_local=preflight   allowed when afx-preflight.sh passes; slot-wrapped jobs get the raised load ceiling
    //   heavy_local=slots       as preflight, but heavy work MUST be slot-wrapped (the M1 Max / 64 GB MacBook Pro)
    if (heavyPolicy === "none") {
      return { block: "this machine is retired from builds (machine.conf heavy_local=none): run installs/typecheck/builds on the primary Mac or on Replit via afx-remote-gate.sh" };
    }
    if (heavyPolicy === "slots" && !slotWrapped) {
      return { block: "heavy local work must hold a gate slot (max 3 at once): run it as `scripts/afx-guard/afx-gate-run.sh <REPO> <label> -- <command>` or `source scripts/afx-guard/afx-gate-slots.sh; afx_gate_acquire <REPO> <label> || exit 97; <ONE install or tsc/test>; afx_gate_release` in ONE bash invocation" };
    }
    if (heavyPolicy === "ship-only" && !existsSync(FREEZE_FILE)) {
      // AGENT_RULES "Where to work": the 8 GB Mac is reserved for Xcode ships. Ship owners
      // declare `afx-freeze.sh on "<ship>" <repo>`, which allows heavy work in that repo only.
      return { block: "the Mac is reserved for iOS ships: run installs/typecheck/builds on Replit via afx-remote-gate.sh. A ship owner declares `afx-freeze.sh on \"<ship>\" <repo>` to build locally; a Mac with 64 GB can set heavy_local=slots in machine.conf" };
    }
    if (existsSync(FREEZE_FILE)) {
      const f = readFileSync(FREEZE_FILE, "utf8");
      const allowed = (f.match(/^allow:\s*(.+)$/m)?.[1] || "").split(/[,\s]+/).filter(Boolean);
      const here = resolve(dir);
      if (!allowed.some((a) => here.includes(`/_clones/${a}`))) {
        return { block: `heavy local work is frozen (${FREEZE_FILE}): ${(f.match(/^reason:\s*(.+)$/m)?.[1] || "see file")}. Run it on Replit via afx-remote-gate.sh, or wait for the freeze owner to lift it` };
      }
    }
    const pre = join(GUARD_DIR, "afx-preflight.sh");
    if (existsSync(pre)) {
      // Slot-wrapped work gets at least 40 (a floor): the owner's machine.conf `max_load=` still applies when it is higher.
      const preArgs = slotWrapped ? (process.env.AFX_GATE_MAX_LOAD ? ["--max-load", process.env.AFX_GATE_MAX_LOAD] : ["--min-max-load", "40"]) : [];
      try { execFileSync("bash", [pre, ...preArgs], { stdio: "ignore", timeout: 20000 }); }
      catch { return { block: "afx-preflight.sh says the machine is busy or short on disk. Do not retry in a loop. Either wrap the command in a gate slot, which queues heavy jobs one at a time and allows a higher load: `scripts/afx-guard/afx-gate-run.sh <repo> <label> -- <command>` (afx-land.sh already does this for its gate), or run it on Replit with afx-remote-gate.sh, or wait" }; }
    }
  }
  return {};
}


// Named read-only probes (registry/remote-probes.txt; installed as remote-probes.txt next to this hook). `name | command`, exact match.
export function parseProbes(text) {
  const out = new Map();
  for (const line of String(text || "").split("\n")) {
    const t = line.trim(); if (!t || t.startsWith("#")) continue;
    const i = t.indexOf("|"); if (i < 1) continue;
    const name = t.slice(0, i).trim(), cmd = t.slice(i + 1).trim().replace(/\s+/g, " ");
    if (/^[a-z0-9-]+$/.test(name) && cmd) out.set(name, cmd);
  }
  return out;
}
function readProbesFile() {
  for (const f of [join(GUARD_DIR, "remote-probes.txt"), join(GUARD_DIR, "..", "registry", "remote-probes.txt")]) { try { return readFileSync(f, "utf8"); } catch {} }
  return "";
}
// True only when the WHOLE command is `ssh [-i key] [-o opt] <host> '<one allowlisted probe command>'`: nothing before, nothing chained after.
// A double-quoted command containing $ or a backtick is refused (the local shell would expand it before the repl sees it).
export function allowlistedProbe(c, probesText) {
  const probes = new Set(parseProbes(probesText ?? readProbesFile()).values());
  if (!probes.size) return false;
  const m = String(c).trim().match(/^(?:\S*\/)?ssh((?:\s+(?:-[io]\s+\S+|-[A-Za-z]))*)\s+([^\s'"-]\S*)\s+(?:'([^'\n]*)'|"([^"\n$`\\]*)")\s*(?:2>&1)?$/);
  if (!m) return false;
  if (!/replit\.dev|\.ssh\/replit/.test(m[1] + " " + m[2])) return false;
  return probes.has((m[3] ?? m[4]).trim().replace(/\s+/g, " "));
}

// What an ad-hoc `ssh <replit>` command is trying to do that only the sanctioned tools may do. Returns a short
// description or null for a read-only probe. Deliberately blunt: a false positive costs one switch to afx-remote-ops.
export function adhocSshWrite(c) {
  const after = c.replace(/^[\s\S]*?\bssh\b/, "");
  const tests = [
    [/(^|[^&0-9])>>?\s*(?!\/dev\/null|&)[~$\w\/."'-]/, "redirect output into a file"],
    [/\b(rm|mv|cp|tee|touch|mkdir|rmdir|chmod|chown|truncate|ln|dd|kill|pkill|killall|install)\s/, "run a file-changing or process command"],
    [/\bsed\s+-i/, "edit files in place"],
    [/\bgit\s+(-C\s+\S+\s+)?(pull|merge|reset|checkout|switch|commit|push|clean|stash|rebase|add|apply|am|cherry-pick|restore|rm|mv|worktree|branch\s+-[dDmM]|config)\b/, "change git state"],
    [/\b(pnpm|npm|npx|yarn|drizzle-kit|psql|pg_dump|wget)\s|\bcurl\s+[^|;]*-X|\b(bash|sh)\s+-c\b/, "run code, a package manager or a database client"],
    [/(^|[;&|'"(]\s*)(node|tsx|python3?)\s/, "run code"],
    [/\b(DROP|TRUNCATE|DELETE\s+FROM|INSERT\s+INTO|UPDATE\s+\w+\s+SET|ALTER\s+TABLE|CREATE\s+TABLE)\b/i, "run SQL"],
  ];
  for (const [re, what] of tests) if (re.test(after)) return what;
  return null;
}

// Heredoc bodies fed to data consumers (python/node/cat/tee/…) are file content or code for
// another interpreter, not shell commands: don't pattern-match docs that *mention* a rule.
// Heredocs fed to a shell (bash/sh/zsh/ssh) are kept and checked.
export function stripDataHeredocs(cmd) {
  return cmd.replace(/(\b(\S+)[^\n]*?<<-?\s*(['"]?)(\w+)\3[^\n]*\n)([\s\S]*?\n)\4(?=\s|$)/g, (m, head, prog, _q, tag) =>
    /^(bash|sh|zsh|ssh|eval|source)$/.test(prog.split("/").pop()) ? m : `${head}${tag}`);
}

// Message/body arguments are prose, not commands: a commit message saying "fix tsc errors"
// must not trip the heavy-work rule (reported by a coordinator session, 2026-09-28).
export function stripMessageArgs(cmd) {
  return cmd.replace(/(\s(?:-m|--message|--body|--title|--notes|--description|--subject)(?:\s+|=))("(?:[^"\\]|\\.)*"|'[^']*'|\$\(cat <<[\s\S]*?\)\s*"?)/g, '$1""');
}

// ── Owner prompt log (verified overrides) ───────────────────────────────────
const norm = (t) => String(t || "").toLowerCase().replace(/\s+/g, " ").trim();
export function ownerSaidIn(logText, words, now = Date.now()) {
  const w = norm(words);
  if (w.length < 3) return false;
  return String(logText || "").split("\n").some((l) => {
    const m = l.match(/^(\d{4}-\d{2}-\d{2}T[\d:.]+Z)\t(.*)$/);
    return m && now - Date.parse(m[1]) < 24 * 3600e3 && norm(m[2].replace(/\\n/g, " ")).includes(w);
  });
}
function ownerSaid(words) { try { return ownerSaidIn(readFileSync(OWNER_LOG, "utf8"), words); } catch { return false; } }
// Only the owner's typed prompts: cross-session messages, task notifications and system
// reminders arrive wrapped in <tags> and must never count as owner approval.
export function isOwnerPrompt(p) { return !!p && !/^\s*</.test(p); }
function logOwnerPrompt(p) {
  if (!isOwnerPrompt(p)) return;
  try { appendFileSync(OWNER_LOG, `${new Date().toISOString()}\t${String(p).slice(0, 2000).replace(/\n/g, "\\n")}\n`, { mode: 0o600 }); } catch {}
}

// ── One destination per machine (owner's top concern) ───────────────────────
// afx-where-am-i.sh already BLOCKS writes outside the destination on every session/subagent.
// This is the detective half: a second AFX tree can already exist (created before the hooks, by
// the Replit Agent, or mid-move) and where-am-i never sees it. The background sweep is TCC-blind
// from ~/Downloads, but a session hook runs with the user's own disk access, so this catches it on
// EVERY session start, every machine. Cheap: shallow find over known spots, short timeout.
export function findStrayDestinations(clones = CLONES) {
  const canon = resolve(dirname(clones)); // the one projects root
  const spots = ["Downloads", "Desktop", "Documents", "Development", "Developer", "code", "Code", "Projects", "projects", "src", "dev", "work", "repos"]
    .map((d) => join(HOME, d)).concat(["/tmp", "/private/tmp"]);
  const found = new Set();
  for (const spot of spots) {
    if (!existsSync(spot)) continue;
    let out = "";
    try { out = execFileSync("find", [spot, "-maxdepth", "4", "-type", "d", "-name", "_clones", "-not", "-path", "*/node_modules/*"], { encoding: "utf8", timeout: 4000, stdio: ["ignore", "pipe", "ignore"] }); } catch {}
    for (const line of out.split("\n")) {
      const d = line.trim(); if (!d) continue;
      if (resolve(dirname(d)) !== canon) found.add(d);
    }
  }
  return [...found];
}

// Recursive delete under ~/Projects (rm -r, Remove-Item -Recurse, rd/rmdir /s), ported from the legacy per-machine guardrd.js. Build
// output (node_modules, dist, ...) stays deletable: the owner OK'd removing regenerable folders (2026-10-20).
const SAFE_DELETE = new Set(["node_modules", "dist", "build", ".next", ".expo", ".turbo", ".cache", "coverage", "out", ".vite", ".parcel-cache", "__pycache__", ".pytest_cache", "tmp", "temp", ".tsbuildinfo"]);
export function projectsRecursiveDelete(c) {
  const m = c.match(/(?:^|[\s;&|(])(rm|rmdir|rd|Remove-Item|ri)\b([^|;&\n]*)/i);
  if (!m) return null;
  const tool = m[1].toLowerCase(), rest = m[2];
  const recursive = tool === "rm" ? /\s-\w*r/i.test(rest) || /--recursive/.test(rest) : tool === "remove-item" || tool === "ri" ? /-Recurse\b/i.test(rest) : /\/s\b/i.test(rest);
  if (!recursive) return null;
  const under = /(?:[a-z]:)?[\\/]+users[\\/]+[^\\/\s"']+[\\/]+projects\b|\/c\/users\/[^/\s"']+\/projects\b|(?:~|\$HOME|\$env:USERPROFILE|%USERPROFILE%)[\\/]+projects\b/i.test(rest);
  if (!under) return null;
  const targets = (rest.match(/"[^"]+"|'[^']+'|\S+/g) || []).map((t) => t.replace(/^["']|["']$/g, "")).filter((t) => !/^-/.test(t) && !/^\/[A-Za-z]$/.test(t) && !/^\$?(true|false)$/i.test(t));
  if (targets.length && targets.every((t) => SAFE_DELETE.has(t.replace(/[\\/]+$/, "").split(/[\\/]/).pop().toLowerCase()))) return null;
  return "nothing under ~/Projects is deleted by an agent: move it to Projects/Archive/Code-Consolidation-2026-09/<Project>/ with a MANIFEST.md line, or ask the owner (build folders such as node_modules and dist are allowed)";
}

// ── SessionStart briefing (stdout becomes session context) ───────────────────
function briefing() {
  const lines = [];
  const rd = (f) => { try { return readFileSync(f, "utf8"); } catch { return ""; } };
  const conf = rd(join(GUARD_DIR, "machine.conf"));
  lines.push(`AFX briefing: machine=${conf.match(/^machine=(.+)$/m)?.[1] || "unknown"}; heavy_local=${conf.match(/^heavy_local=(\S+)/m)?.[1] || "default"}.`);
  const fz = rd(FREEZE_FILE);
  lines.push(fz ? `FREEZE ON: ${fz.match(/^reason:\s*(.+)$/m)?.[1]} (allow: ${fz.match(/^allow:\s*(.+)$/m)?.[1]}). Heavy local work elsewhere is blocked.` : "No freeze declared.");
  const gi = rd(join(GUARD_DIR, "git-integrity")).trim();
  if (/^BAD/.test(gi)) lines.push(`🔴 GIT INTEGRITY: a clone's object store is damaged (${gi.slice(4)}). Don't gc/prune/repack it; repair by moving the bad pack aside and restoring objects from GitHub (quickstart troubleshooting).`);
  const st = rd(join(GUARD_DIR, "sweep-status")).trim();
  if (/^BLIND/.test(st)) lines.push(`⚠️ SWEEP ${st}`);
  else if (!st) lines.push("⚠️ Sweep status unknown (no run recorded on this machine): the 2h backstop may not be running.");
  const fr = rd(join(READINESS, "FRAGMENTS_LATEST.md"));
  if (fr) {
    const when = fr.match(/^# Fragment sweep: .*?, (.+)$/m)?.[1] || "?";
    const n = (re) => (fr.match(re) || []).length;
    lines.push(`Last sweep ${when}: ${n(/^PRESERVE /gm)} worktrees with uncommitted work >8h, ${n(/^WARN /gm)} >4h, ${n(/ UNPUSHED /g)} unpushed branches, ${n(/FAILED/g)} failed preserves (_readiness/FRAGMENTS_LATEST.md).`);
  }
  const ov = rd(join(READINESS, "OVERRIDES.log")).split("\n").filter((l) => l && Date.now() - Date.parse(l.slice(0, 16).replace(" ", "T") + ":00Z") < 7 * 864e5).length;
  if (ov) lines.push(`${ov} AFX_OWNER_OK override(s) in the last 7 days (_readiness/OVERRIDES.log).`);
  const appr = rd(APPROVALS).split("\n").filter(Boolean);
  const active = [...new Set(appr.map((l) => l.split(/\s+/)[0]).filter((m) => m && m !== "revoke"))].filter((m) => approvalState(appr.join("\n"), m));
  lines.push(active.length ? `Owner-approved models beyond haiku/sonnet right now: ${active.join(", ")}.` : "Subagents: haiku by default, sonnet when needed; higher needs the owner's approve-model.");
  lines.push("Tip: load the afx-ai-toolkit skill for substantial planning/review work and for the owner shortcuts (Proceed / Checking in / Recap / Summary Table).");
  try {
    const stray = findStrayDestinations();
    if (stray.length) lines.push(`🚨 FRAGMENTATION: a second AFX tree exists outside the one destination (${CLONES}): ${stray.join(", ")}. Preserve it to GitHub, consolidate to the canonical root, then remove the copy. Do NOT work in it.`);
    else lines.push(`One destination confirmed: ${CLONES} (no stray AFX trees found).`);
  } catch {}
  try {
    // Fleet roster (registry/fleet.json on origin/main): which device this is and where heavy work goes.
    const fl = JSON.parse(git(HUB, "show", "origin/main:scripts/afx-guard/registry/fleet.json") || "null");
    if (fl?.devices) {
      const key = confKey("registry");
      const me = fl.devices.find((d) => d.key === key);
      const others = fl.devices.filter((d) => d !== me).map((d) => `${d.name}${d.ramGb ? ` ${d.ramGb} GB` : ""}`).join(", ");
      const who = me ? `This is ${me.name}${me.ramGb ? ` (${me.ramGb} GB)` : ""}: ${me.role} Heavy work: ${me.heavyWork || "n/a"}.`
        : key ? `This machine's registry=${key} is not in fleet.json.` : "This machine has no registry= in machine.conf (afx-machine-conf.sh).";
      lines.push(`${who} Also in the fleet: ${others}; Replit VMs via afx-remote-gate.sh / afx-remote-ops.sh (hub scripts/afx-guard/registry/fleet.json).`);
    }
  } catch {}
  try {
    const raw = git(HUB, "show", "origin/main:ops/readiness/_readiness/BRANCH_DEBT_BACKLOG.json");
    const t = raw && JSON.parse(raw);
    if (t?.totals) {
      const debt = (t.totals["CLEAN-AHEAD"] || 0) + (t.totals.CONFLICT || 0) + (t.totals["NO-BASE"] || 0);
      lines.push(`Branch debt (${t.generated}, ${t.machine}): ${debt} branches hold content that is not in main, plus ${t.totals.PRESERVED || 0} snapshot branches not yet reconciled (hub ops/readiness/_readiness/BRANCH_DEBT_BACKLOG.json). Do not add to it.`);
    }
  } catch {}
  try {
    // main stays green (owner rule 2026-10-13): show every repo whose CURRENT main failed its full gate (afx-main-health.sh)
    const mh = rd(join(READINESS, "MAIN_HEALTH.tsv")).split("\n").filter(Boolean).map((l) => l.split("\t"));
    const red = mh.filter(([, repo, sha, rc]) => rc !== "0" && (git(join(CLONES, repo), "rev-parse", "origin/main") || "").startsWith(sha));
    if (red.length) lines.push(`🔴 MAIN IS RED in ${red.map(([when, repo, , , errs, first]) => `${repo} (${errs} type errors${first ? `, first failing ${first}` : ""}, tested ${when})`).join("; ")}. Only the fix may land there (afx-land.sh --fixes-main); see afx-main-health.sh --status.`);
    else if (mh.length) lines.push(`Main health: no red main among ${mh.length} recorded repo(s) (afx-main-health.sh --status).`);
  } catch {}
  lines.push("DONE MEANS MERGED: a task is finished only when its change is in main, its branch is deleted and its worktree is removed. Pushed, PR open and rescue branch are not end states. One product, one repo, one path.");
  lines.push("Rules are enforced by hooks (hub docs/AFX_SESSION_QUICKSTART.md): edit only in <repo>/.claude/worktrees/<name>, push within 2h, pnpm only, no force-push/reset --hard/rm -rf on clones, real exit codes. A block is the rule working: ask the owner, don't route around it.");
  return lines.join("\n");
}

// ── Agent (R18) ─────────────────────────────────────────────────────────────
export function checkAgent(t) {
  if (t.subagent_type === "fork") {
    return approved("fork") ? {} : { block: "R18: a fork inherits the parent's model (above Sonnet). Use a haiku/sonnet agent, or get the owner's approval (model-approvals.txt)" };
  }
  const m = (t.model || "").toLowerCase();
  if (!m) return { block: "R18: set `model` explicitly on every Agent call (haiku by default, sonnet when needed)" };
  if (m === "haiku" || m === "sonnet") return {};
  return approved(m) ? { use: m } : { block: `R18: model '${m}' needs the owner's explicit approval first. The owner types \`approve-model ${m} 3d <reason>\` (or \`standing\`) in the prompt, or runs \`! ~/.claude/hooks/afx-guard/afx-approve-model.sh ${m} 3d "<reason>"\`` };
}

// ── Model approvals (R18) ───────────────────────────────────────────────────
// model-approvals.txt, one line each, read in order (a later line overrides an earlier one):
//   <model> <YYYY-MM-DD> [until=<YYYY-MM-DD>|until=standing] owner: <reason>   approve
//   revoke <model> <YYYY-MM-DD> owner: <reason>                                revoke
// A line with no until= is valid on its date only (the original format).
// Only the owner writes this file: via the UserPromptSubmit hook (their own typed prompt)
// or afx-approve-model.sh run with `!`. Tool calls that touch it are blocked below.
const today = () => new Date().toISOString().slice(0, 10);
export function approvalState(text, what, day = today()) {
  let ok = false;
  for (const raw of (text || "").split("\n")) {
    const l = raw.trim();
    if (l.startsWith(`revoke ${what} `)) { ok = false; continue; }
    if (!l.startsWith(what + " ")) continue;
    const date = l.split(/\s+/)[1] || "";
    const until = (l.match(/\buntil=(\S+)/) || [])[1];
    if (until === "standing") ok = true;
    else if (until && /^\d{4}-\d{2}-\d{2}$/.test(until)) ok = date <= day && day <= until;
    else ok = date === day;
  }
  return ok;
}
function approved(what) {
  try { return approvalState(readFileSync(APPROVALS, "utf8"), what); } catch { return false; }
}
// Parses the owner's prompt: `approve-model <model> [<N>d|standing] [reason…]` or
// `revoke-model <model> [reason…]`, only at the very start of the prompt (a leading `/` is
// allowed). Cross-session messages and task notifications start with `<`, so they never match.
export function parseApprovalPrompt(prompt, day = today()) {
  const m = String(prompt || "").match(/^\/?(approve-model|revoke-model)\s+([a-z0-9.-]+)(?:\s+(\d{1,3}d|standing))?\s*([\s\S]*)$/i);
  if (!m) return null;
  const [, verb, model, span, reason] = m;
  const why = (reason || "").trim().split("\n")[0].slice(0, 200) || "(no reason given)";
  const mod = model.toLowerCase();
  if (verb.toLowerCase() === "revoke-model") return { line: `revoke ${mod} ${day} owner: ${why}`, msg: `revoked ${mod}` };
  let until = "";
  if (span && span.toLowerCase() === "standing") until = " until=standing";
  else if (span) {
    const d = new Date(`${day}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + Math.max(1, parseInt(span, 10)) - 1);
    until = ` until=${d.toISOString().slice(0, 10)}`;
  }
  return { line: `${mod} ${day}${until} owner: ${why}`, msg: `approved ${mod}${until ? ` (${until.trim()})` : " (today only)"}` };
}


// ── Prod migration approvals (afx-remote-ops.sh migrate-apply --prod) ───────────────────────────────────────
// The owner types `approve-prod <venture|all> [<N>h|standing] <reason>` at the very start of a prompt; the
// UserPromptSubmit hook (owner prompts only, never a tool call) writes a 0600 token file that
// afx-remote-ops.sh validates (venture, expiry, directory). Time-boxed tokens are consumed on use; `standing`
// tokens persist until the owner types `revoke-prod <venture>`. Tool calls that touch the directory are blocked.
export function parseProdApprovalPrompt(prompt, now = Date.now()) {
  const m = String(prompt || "").match(/^\/?(approve-prod|revoke-prod)\s+([A-Za-z0-9._-]+)(?:\s+(\d{1,3}h|standing))?\s*([\s\S]*)$/i);
  if (!m) return null;
  const [, verb, venture, span, reason] = m;
  const why = (reason || "").trim().split("\n")[0].slice(0, 200) || "(no reason given)";
  if (verb.toLowerCase() === "revoke-prod") return { revoke: venture, msg: `revoked prod approvals for ${venture}` };
  const hours = span && /h$/i.test(span) ? parseInt(span, 10) : 2;
  const expires = span && /standing/i.test(span) ? "standing" : String(Math.floor(now / 1000) + hours * 3600);
  return { venture, expires, why, msg: `approved prod migrations for ${venture} (${expires === "standing" ? "standing" : hours + "h, single use"})` };
}

// ── Write/Edit content ──────────────────────────────────────────────────────
export function checkContent(path, text) {
  if (/owner-prompts\.log$/.test(path || "")) return { block: "the owner prompt log is written only by the owner's own prompts" };
  if (/(replit-ops-ledger\.jsonl|\/prod-approvals\/)/.test(path || "")) return { block: "the Replit ops ledger and prod approvals are written only by afx-remote-ops.sh and the owner's own prompts" };
  if (/model-approvals\.txt$/.test(path || "")) return { block: "R18: model approvals are the owner's to grant (approve-model in the prompt), never written by a tool call" };
  if (/spend-approvals\.txt$/.test(path || "")) return { block: "R19: spend approvals are the owner's to grant (approve-spend in the prompt), never written by a tool call" };
  if (!text || /(^|\/)\.env(\.\w+)?$/.test(path || "")) return {};
  const secrets = [
    [/\bsk_live_[0-9A-Za-z]{16,}/, "Stripe live secret key"],
    [/\brk_live_[0-9A-Za-z]{16,}/, "Stripe restricted live key"],
    [/\bwhsec_[0-9A-Za-z]{20,}/, "Stripe webhook secret"],
    [/\bre_[0-9A-Za-z]{8}_[0-9A-Za-z]{16,}/, "Resend API key"],
    [/\bgh[pousr]_[0-9A-Za-z]{30,}/, "GitHub token"],
    [/\bAKIA[0-9A-Z]{16}\b/, "AWS access key"],
    [/\bsk-ant-[0-9A-Za-z_-]{20,}/, "Anthropic API key"],
    [/-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----/, "private key"],
    [/postgres(ql)?:\/\/[^:\s]+:[^@\s]{8,}@[^\s]+neon\.tech/, "Neon database URL with password"],
  ];
  for (const [re, what] of secrets) if (re.test(text)) return { block: `${what} in file content: secrets go in Replit Secrets / .env (gitignored), never in tracked files` };
  return {};
}

// ── Stop: push before ending ────────────────────────────────────────────────
// (sync-guard a) Covers BOTH a worktree and the main checkout. A worktree is flagged on any
// uncommitted or unpushed work. The main checkout (_clones/<repo>, not a worktree) is read/
// fetch-only and legitimately carries untracked worktree dirs, so it is flagged only on
// unpushed COMMITS — those are real work that gets lost, and a commit on the main checkout is
// itself off-policy (work belongs in a worktree).
// Done means merged (owner directive 2026-10-08, Operating Standard section 2). A worktree whose
// work is committed and pushed is still not finished: "merged" = its content is in origin/main
// (ancestor, or a merge would change nothing, which also covers squash and cherry-pick merges).
//   "none"     no commits beyond origin/main: nothing to merge
//   "unmerged" pushed work whose content is not in origin/main yet
//   "leftover" content is in origin/main but the branch/worktree is still here
export function doneKind(aheadOfMain, contained, remoteBranchExists = false, prMerged = false) {
  // The pull request for exactly this branch tip is merged on GitHub (a squash merge whose content main has since changed again defeats the
  // content test): the work is landed, only the cleanup is left.
  if (prMerged) return "leftover";
  // Nothing beyond main and never pushed: a fresh worktree. Nothing beyond main but the branch is
  // still on the remote: it was merged with a merge commit and never cleaned up.
  if (!aheadOfMain && contained) return remoteBranchExists ? "leftover" : "none";
  return contained ? "leftover" : "unmerged";
}
// Git on Windows (Git Bash / PowerShell) can hand back C:\\ style paths: compare and print forward slashes only.
export const normPath = (p) => String(p || "").replace(/\\/g, "/");
// The exact command that lands a pushed-but-unmerged branch. `bash` first so it runs the same in Git Bash and PowerShell. A change whose
// files are all docs may use --gate-docs-only (the same rule afx-land.sh applies); anything else needs the repo's real gate command, which
// this hook cannot know and will not invent.
export function landCommand(top, scriptPath, docsOnly) {
  const gate = docsOnly ? "--gate-docs-only" : '--gate "<the repo gate command, e.g. pnpm run typecheck:libs && pnpm run test>"';
  return `cd "${normPath(top)}" && bash "${normPath(scriptPath)}" ${gate} && bash "${normPath(scriptPath)}" --cleanup`;
}
export const isDocsOnly = (files) => files.length > 0 && files.every((f) => /(\.md$|^docs\/|\/docs\/)/.test(f));
// True when GitHub says the PR whose head is exactly `tip` is merged. Any failure (no gh, offline, not logged in) means "unknown": false.
function prMergedForTip(top, branch, tip) {
  try {
    const out = execFileSync("gh", ["pr", "list", "--head", branch, "--state", "merged", "--limit", "10", "--json", "headRefOid"], { cwd: top, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 8000 });
    return JSON.parse(out || "[]").some((p) => p.headRefOid === tip);
  } catch { return false; }
}
export function stopKind(isWorktree, isMainCheckout, ahead, dirty) {
  if (isWorktree) return (dirty || ahead) ? "worktree" : "ok";
  if (isMainCheckout) return ahead ? "main" : "ok";
  return "ok";
}
function checkStop() {
  if (input.stop_hook_active) return {};
  const top = normPath(git(cwd, "rev-parse", "--show-toplevel"));
  if (!top) return {};
  const isWorktree = top.includes("/.claude/worktrees/");
  const isMainCheckout = !isWorktree && /\/_clones\/[^/]+$/.test(top);
  if (!isWorktree && !isMainCheckout) return {};
  let ahead = Number(git(top, "rev-list", "--count", "HEAD", "--not", "--remotes") || 0);
  if (ahead) {
    // A clone that only tracks main (remote.origin.fetch = +refs/heads/main:...) never updates
    // refs/remotes/origin/<branch>, so a pushed branch looks unpushed. Ask the remote itself.
    const cur = git(top, "rev-parse", "--abbrev-ref", "HEAD");
    const remoteSha = cur && cur !== "HEAD" ? (git(top, "ls-remote", "origin", `refs/heads/${cur}`) || "").split(/\s+/)[0] : "";
    if (remoteSha && remoteSha === git(top, "rev-parse", "HEAD")) ahead = 0;
  }
  // Only scan the working tree for a worktree; the main checkout legitimately holds untracked
  // worktree dirs, so dirty there is noise — it is flagged on unpushed commits alone.
  const dirty = isWorktree ? (git(top, "status", "--porcelain") || "").split("\n").filter(Boolean).length : 0;
  const kind = stopKind(isWorktree, isMainCheckout, ahead, dirty);
  if (kind === "main") {
    const branch = git(top, "rev-parse", "--abbrev-ref", "HEAD") || "?";
    return { block: `the MAIN checkout ${top} has ${ahead} unpushed commit(s) on ${branch}. The main checkout is read/fetch-only — work belongs in <repo>/.claude/worktrees/<name>. Push these commits (or move them to a branch) before ending: an unpushed commit on the main checkout gets lost` };
  }
  if (kind === "worktree") return { block: `worktree ${top} has ${dirty} uncommitted file(s) and ${ahead} unpushed commit(s). Commit and push your branch (or say explicitly why not) before ending: unpushed work is unfinished work` };
  if (isWorktree) {
    // Fresh view of main; if the network or the merge test fails, stay silent rather than guess.
    git(top, "fetch", "-q", "origin", "main");
    const mainSha = git(top, "rev-parse", "--verify", "-q", "FETCH_HEAD") || git(top, "rev-parse", "--verify", "-q", "origin/main");
    const mainTree = mainSha && git(top, "rev-parse", `${mainSha}^{tree}`);
    const merged = mainSha && (git(top, "merge-tree", "--write-tree", mainSha, "HEAD") || "").split("\n")[0];
    const aheadOfMain = mainSha ? Number(git(top, "rev-list", "--count", `${mainSha}..HEAD`) || 0) : 0;
    if (mainTree && merged && /^[0-9a-f]{40,64}$/.test(merged)) {
      const branch = git(top, "rev-parse", "--abbrev-ref", "HEAD") || "?";
      const onRemote = branch !== "HEAD" && !!(git(top, "ls-remote", "origin", `refs/heads/${branch}`) || "").trim();
      let done = doneKind(aheadOfMain, merged === mainTree, onRemote);
      if (done === "unmerged") { const tip = git(top, "rev-parse", "HEAD"); if (tip && prMergedForTip(top, branch, tip)) done = doneKind(aheadOfMain, merged === mainTree, onRemote, true); }
      if (done === "unmerged") {
        const files = (git(top, "diff", "--name-only", `${mainSha}...HEAD`) || "").split("\n").filter(Boolean).map(normPath);
        const own = join(top, "scripts/afx-guard/afx-land.sh");
        const script = existsSync(own) ? own : join(HUB, "scripts/afx-guard/afx-land.sh");
        return { block: `branch ${branch} in ${top} is pushed but NOT landed: its tip is not in origin/main (${aheadOfMain} commit(s) whose content is not there) and no merged pull request has this tip. Done means merged (Operating Standard section 2). Land it now: \`${landCommand(top, script, isDocsOnly(files))}\` (owner decision 2026-10-08: agents merge their own work through that tool; protected paths and mass deletions need the owner-ok label), or say in your final message exactly who owns the merge and by when. A pushed branch is not a finished task.` };
      }
      if (done === "leftover") return { block: `branch ${branch} in ${top} is already landed (its content is in origin/main or its pull request is merged) but the branch and worktree are still here. Finish the task: \`cd "${top}" && bash scripts/afx-guard/afx-land.sh --cleanup\` (it confirms the tip is on GitHub first and prints the one-line manual command if the folder cannot be removed). On Windows a "Permission denied" while removing the folder means an editor, terminal or antivirus holds it: close that and retry, or leave it, because it is not lost work and afx-worktree-clean.sh removes it later. If land --cleanup refuses (a squash-merged branch deleted on GitHub), the fallback after you confirm nothing is uncommitted is \`git worktree remove "${top}"\`. Never rm -rf; never --force.` };
    }
  }
  return {};
}

// ── SubagentStop: token ledger ──────────────────────────────────────────────
// Row shape (the reader afx-token-kpis.sh depends on it; do not change field order):
//   | YYYY-MM-DD HH:MM | repo | auto:<agentId> | <model|?> | <tokens|unknown> | <note> |
// Two writer bugs made ~94% of rows "? | unknown" (1257 of 1334 on 2026-10-02) or undercounted:
//  1. The transcript was read from agent_transcript_path only, once, with the error swallowed;
//     when that path was missing/not yet flushed the row carried no number at all. Now: try the
//     given path, then the path derived from transcript_path + agent_id, then a bounded retry.
//  2. The harness streams each API message as several transcript lines that share one message id
//     (the first has no output_tokens yet). The old dedupe kept the FIRST line, so output tokens
//     were dropped. Now the LAST line per message id wins.
// A row that still cannot be measured says WHY in its note (reason=...), so "unknown" is never silent.
export function sumTranscript(text) {
  const byId = new Map();
  let n = 0;
  for (const line of String(text).split("\n")) {
    if (!line) continue;
    let j; try { j = JSON.parse(line); } catch { continue; }
    const m = j?.message; if (!m?.usage) continue;
    byId.set(m.id || j.uuid || `line${n++}`, { model: m.model, u: m.usage });
  }
  let tokens = 0, cacheRead = 0, model = "?";
  for (const { model: mo, u } of byId.values()) {
    if (mo && mo !== "<synthetic>") model = mo;
    // Matches the harness's subagent_tokens: input + output + cache writes. Cache reads listed apart.
    tokens += (u.input_tokens || 0) + (u.output_tokens || 0) + (u.cache_creation_input_tokens || 0);
    cacheRead += u.cache_read_input_tokens || 0;
  }
  return { tokens, cacheRead, model, messages: byId.size };
}
export function transcriptCandidates(inp) {
  const c = [];
  if (inp.agent_transcript_path) c.push(inp.agent_transcript_path);
  const id = inp.agent_id;
  const tp = inp.transcript_path;
  if (id && tp) c.push(join(String(tp).replace(/\.jsonl$/, ""), "subagents", `agent-${id}.jsonl`));
  if (!id && tp) c.push(tp);
  return c;
}
function sleepMs(ms) { try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch {} }
function ledger() {
  let r = null, reason = "no-transcript-path";
  const cands = transcriptCandidates(input);
  for (let attempt = 0; attempt < 3 && !(r && r.tokens); attempt++) {
    if (attempt) sleepMs(300);
    for (const p of cands) {
      reason = "transcript-missing";
      try {
        const x = sumTranscript(readFileSync(p, "utf8"));
        if (x.messages) { r = x; break; }
        reason = "no-usage-lines";
      } catch { /* try the next candidate */ }
    }
  }
  const { tokens, cacheRead, model } = r || { tokens: 0, cacheRead: 0, model: "?" };
  const repo = (git(cwd, "rev-parse", "--show-toplevel") || cwd).split("/_clones/")[1]?.split("/")[0] || "-";
  const note = tokens ? `SubagentStop hook (cache reads ${cacheRead})` : `SubagentStop hook (cache reads 0; reason=${reason})`;
  log(join(READINESS, "TOKEN_LEDGER.md"), `| ${stamp()} | ${repo} | auto:${input.agent_id || input.agent_type || "subagent"} | ${model} | ${tokens || "unknown"} | ${note} |`);
  if (tokens > 750000) process.stderr.write(`⚠️ TOKEN FLAG: subagent used ${(tokens / 1e6).toFixed(2)}M tokens\n`);
}

// ── dispatch ────────────────────────────────────────────────────────────────
if (IS_MAIN) {
  let r = {};
  if (event === "PreToolUse" && isShellTool(tool)) {
    r = checkBash(ti.command || "");
    if (!r.block) { const sb = scratchCopyBash(ti.command || ""); if (sb) r = { block: sb }; }
    if (r.override) { log(join(READINESS, "OVERRIDES.log"), `${stamp()} ${cwd} :: ${String(ti.command).slice(0, 300)}`); r = {}; }
  } else if (event === "PreToolUse" && (tool === "Agent" || tool === "Task")) {
    r = checkAgent(ti);
    if (r.use) log(join(READINESS, "MODEL_USE.log"), `${stamp()} ${r.use} :: ${String(ti.description || "").slice(0, 120)} :: ${cwd}`);
  } else if (event === "SessionStart") {
    process.stdout.write(briefing() + "\n");
  } else if (event === "UserPromptSubmit") {
    logOwnerPrompt(input.prompt);
    const pa = parseProdApprovalPrompt(input.prompt);
    if (pa) {
      const dir = join(GUARD_DIR, "prod-approvals");
      try {
        mkdirSync(dir, { recursive: true, mode: 0o700 });
        if (pa.revoke) { for (const f of readdirSync(dir)) if (f.startsWith(pa.revoke + "-") && f.endsWith(".token")) unlinkSync(join(dir, f)); }
        else writeFileSync(join(dir, `${pa.venture}-${Date.now()}.token`), `venture=${pa.venture}\nexpires=${pa.expires}\nreason=${pa.why}\ncreated=${new Date().toISOString()}\nsource=owner-prompt\n`, { mode: 0o600 });
        log(join(READINESS, "MODEL_USE.log"), `${stamp()} owner ${pa.msg}`);
        process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: `AFX: the owner just ${pa.msg}. Pass the token with afx-remote-ops.sh <venture> migrate-apply --prod --apply --approval-token ${dir}/<file>.token (dev-first and every other safety still apply).` } }));
      } catch {}
    }
    const sa = parseSpendPrompt(input.prompt);
    if (sa) {
      log(SPEND_APPROVALS, sa.line);
      log(join(READINESS, "MODEL_USE.log"), `${stamp()} owner ${sa.msg}`);
      process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: `AFX R19: the owner just ${sa.msg}. Loops and scripts of model calls are allowed while it is valid. Still keep it small: say the run count and models up front, record each run's cost, and stop when the question is answered.` } }));
    }
    const a = parseApprovalPrompt(input.prompt);
    if (a) {
      log(APPROVALS, a.line);
      log(join(READINESS, "MODEL_USE.log"), `${stamp()} owner ${a.msg}`);
      process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: `AFX R18: the owner just ${a.msg} (model-approvals.txt line: "${a.line}"). Agents on that model are allowed while it's valid; log their token use.` } }));
    }
  } else if (event === "PreToolUse" && /^(Write|Edit|MultiEdit)$/.test(tool)) {
    const text = ti.content ?? ti.new_string ?? (Array.isArray(ti.edits) ? ti.edits.map((e) => e.new_string).join("\n") : "");
    const ge = guardEdit(ti.file_path, ti);
    const sc = scratchCopy(ti.file_path);
    r = ge ? { block: ge } : sc ? { block: sc } : checkContent(ti.file_path, text);
  } else if (event === "PostToolUse" && /^(Write|Edit|MultiEdit)$/.test(tool)) {
    if (/(CHANGELOG|RELEASE_CLAIMS_LEDGER|release[-_]notes|WHAT_TO_TEST|testflight[-_]notes)/i.test(ti.file_path || "")) {
      process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: "AFX release-claims rule: load the afx-release-claims skill. Every changelog / What-to-Test line needs a matching RELEASE_CLAIMS_LEDGER row with E2E evidence from this session; no 'New' without a live server." } }));
    }
  } else if (event === "SubagentStop") {
    // Ledger only. Subagents share the parent's worktree: a push check here made a test
    // subagent commit the parent's files (2026-09-27). The parent's Stop check covers it.
    ledger();
  } else if (event === "Stop") {
    r = checkStop();
  }
  if (r.block) block(r.block);
  process.exit(0);
}
