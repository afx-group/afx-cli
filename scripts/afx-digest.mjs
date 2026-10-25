#!/usr/bin/env node
// afx-digest.mjs: deterministic digest of a gate log. No model, no judgement, no verdict words.
//
//   node afx-digest.mjs [--type auto|tsc|node-test|vitest|install|tail] [--cmd "<command>"]
//                       [--baseline <tsc-log>] [--tail N] [--top N] < gate.log
//
// Prints only literal numbers copied from the log, names copied from the log, and tail lines. It never
// prints a pass/fail/OK verdict of its own and never invents an exit code: the exit code comes from the
// real run (afx-gate-run.sh prints it next to this digest).
//   tsc        counts per file and per error code (TS6305 excluded, its count shown), net-new vs --baseline
//   node-test  node:test / tsx --test (TAP or spec): tests/pass/fail/skipped/cancelled/todo + failing names
//   vitest     Test Files / Tests totals + FAIL names
//   install    last 15 lines
//   tail       last 40 lines (unknown command types)
// Type "auto" chooses from --cmd first (install / tsc / node --test / vitest), then sniffs the log.
//
// The tsc counting logic (regexes, TS6305 exclusion, baseline multiset diff) is a port of afx-tsc-digest
// (a local-AI digest helper, Python), credited to its author.
import { readFileSync, realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const ANSI = /\x1b\[[0-9;]*[A-Za-z]/g;
const TS_LINE = /^(?<file>[^\s(:][^(:]*?)[(:](?<line>\d+)[,:](?<col>\d+)\)?:?\s*-?\s*error\s+(?<code>TS\d+):\s*(?<msg>.*)$/;
const TS_BARE = /^error\s+(?<code>TS\d+):\s*(?<msg>.*)$/;

export function stripAnsi(s) { return s.replace(ANSI, ""); }
const lines = (text) => { const l = stripAnsi(text).split("\n"); if (l.length && l[l.length - 1] === "") l.pop(); return l; };
const tailOf = (text, n) => lines(text).slice(-n);

export function parseTsc(text, excluded = new Set(["TS6305"])) {
  const errs = []; const skipped = new Map();
  for (const raw of lines(text)) {
    const l = raw.trim();
    const m = TS_LINE.exec(l) || TS_BARE.exec(l);
    if (!m) continue;
    const g = m.groups; const file = g.file || "(no file)";
    if (excluded.has(g.code)) { skipped.set(g.code, (skipped.get(g.code) || 0) + 1); continue; }
    errs.push([file, g.code, g.msg.trim()]);
  }
  return { errs, skipped };
}
const countBy = (arr, f) => { const m = new Map(); for (const x of arr) m.set(f(x), (m.get(f(x)) || 0) + 1); return [...m.entries()].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)); };

export function digestTsc(text, { baselineText = null, top = 25 } = {}) {
  const { errs, skipped } = parseTsc(text);
  const byFile = countBy(errs, (e) => e[0]); const byCode = countBy(errs, (e) => e[1]);
  const out = [];
  let head = `tsc errors (excluding TS6305): ${errs.length} in ${byFile.length} files`;
  if (skipped.size) head += ` | excluded: ${[...skipped].map(([c, n]) => `${c} x${n}`).join(", ")}`;
  out.push(head);
  if (byCode.length) out.push("by code: " + byCode.map(([c, n]) => `${c} x${n}`).join(", "));
  for (const [f, n] of byFile.slice(0, top)) out.push(`  ${String(n).padStart(5)}  ${f}`);
  if (byFile.length > top) out.push(`  ... ${byFile.length - top} more files`);
  if (baselineText !== null) {
    const base = parseTsc(baselineText).errs;
    const left = new Map(); for (const e of base) { const k = e.join("\u0000"); left.set(k, (left.get(k) || 0) + 1); }
    const fresh = [];
    for (const e of errs) { const k = e.join("\u0000"); if ((left.get(k) || 0) > 0) left.set(k, left.get(k) - 1); else fresh.push(e); }
    let gone = 0; for (const v of left.values()) gone += v;
    out.push(`baseline: ${base.length} errors | net-new (file+code+message not in baseline): ${fresh.length} | no longer present: ${gone}`);
    for (const [f, c, msg] of fresh.slice(0, top)) out.push(`  NEW ${f}: ${c}: ${msg.slice(0, 140)}`);
    if (fresh.length > top) out.push(`  ... ${fresh.length - top} more net-new`);
  }
  return out;
}

export function digestNodeTest(text, { top = 30 } = {}) {
  const tot = {}; const failing = [];
  for (const raw of lines(text)) {
    const l = raw.trim();
    let m = /^(?:#|ℹ)\s+(tests|suites|pass|fail|cancelled|skipped|todo)\s+(\d+)\s*$/.exec(l);
    if (m) { tot[m[1]] = (tot[m[1]] || 0) + Number(m[2]); continue; }
    m = /^not ok \d+ - (.*?)(?:\s+#.*)?$/.exec(l) || /^✖ (.*?)(?:\s+\([0-9.]+m?s\))?$/.exec(l);
    if (m && !/^failing tests:?$/i.test(m[1]) && !failing.includes(m[1])) failing.push(m[1]);
  }
  const keys = ["tests", "pass", "fail", "skipped", "cancelled", "todo"];
  const out = [keys.map((k) => `${k}=${tot[k] ?? "n/a"}`).join(" ") + (tot.suites !== undefined ? ` suites=${tot.suites}` : "")];
  if (failing.length) { out.push(`failing test names (${failing.length}):`); for (const n of failing.slice(0, top)) out.push(`  - ${n}`); if (failing.length > top) out.push(`  ... ${failing.length - top} more`); }
  else out.push("failing test names: 0 reported in the log");
  return out;
}

export function digestVitest(text, { top = 30 } = {}) {
  const out = []; const failing = [];
  for (const raw of lines(text)) {
    const l = raw.trim();
    if (/^(Test Files|Tests)\s+\d/.test(l)) out.push(l.replace(/\s{2,}/g, " "));
    const m = /^(?:FAIL|×|✗)\s+(.*?)(?:\s+\d+ms)?$/.exec(l);
    if (m && !failing.includes(m[1])) failing.push(m[1]);
  }
  if (!out.length) out.push("vitest summary lines (Test Files / Tests): none found in the log");
  if (failing.length) { out.push(`failing test names (${failing.length}):`); for (const n of failing.slice(0, top)) out.push(`  - ${n}`); if (failing.length > top) out.push(`  ... ${failing.length - top} more`); }
  else out.push("failing test names: 0 reported in the log");
  return out;
}

export function digestTail(text, n) { return [`last ${n} lines:`, ...tailOf(text, n)]; }

export function detectType(text, cmd = "") {
  const c = cmd || "";
  if (/\b(pnpm|npm|yarn|bun)\s+(install|i|ci|add)\b/.test(c)) return "install";
  if (/vitest/.test(c)) return "vitest";
  if (/(--test\b|node:test)/.test(c)) return "node-test";
  if (/\btsc\b|typecheck/.test(c)) return "tsc";
  const t = stripAnsi(text);
  if (/^(#|ℹ) (tests|pass) \d+/m.test(t)) return "node-test";
  if (/^\s*(Test Files|Tests)\s+\d/m.test(t)) return "vitest";
  if (/error TS\d+/.test(t)) return "tsc";
  return "tail";
}

export function digest(text, { type = "auto", cmd = "", baselineText = null, tail, top } = {}) {
  const ty = type === "auto" ? detectType(text, cmd) : type;
  let body;
  if (ty === "tsc") body = digestTsc(text, { baselineText, top });
  else if (ty === "node-test") body = digestNodeTest(text, { top });
  else if (ty === "vitest") body = digestVitest(text, { top });
  else if (ty === "install") body = digestTail(text, tail ?? 15);
  else body = digestTail(text, tail ?? 40);
  return { type: ty, lines: [`digest type=${ty} (numbers and lines copied from the log)`, ...body] };
}

function main(argv) {
  const o = { type: "auto", cmd: "", baseline: null, tail: undefined, top: undefined };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--type") o.type = argv[++i]; else if (a === "--cmd") o.cmd = argv[++i]; else if (a === "--baseline") o.baseline = argv[++i];
    else if (a === "--tail") o.tail = Number(argv[++i]); else if (a === "--top") o.top = Number(argv[++i]);
    else if (a === "-h" || a === "--help") { console.log(readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").slice(1, 15).map((l) => l.replace(/^\/\/ ?/, "")).join("\n")); return 0; }
    else { console.error(`afx-digest: unknown argument ${a}`); return 2; }
  }
  if (!["auto", "tsc", "node-test", "vitest", "install", "tail"].includes(o.type)) { console.error(`afx-digest: bad --type ${o.type}`); return 2; }
  let baselineText = null;
  if (o.baseline) { try { baselineText = readFileSync(o.baseline, "utf8"); } catch (e) { console.error(`afx-digest: cannot read baseline ${o.baseline}`); return 2; } }
  const text = readFileSync(0, "utf8");
  console.log(digest(text, { type: o.type, cmd: o.cmd, baselineText, tail: o.tail, top: o.top }).lines.join("\n"));
  return 0;
}
// realpath: a symlinked install path (macOS /var -> /private/var, ~/.afx symlinks) must not turn this into a silent no-op
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) process.exit(main(process.argv.slice(2)));
