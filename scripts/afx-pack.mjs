#!/usr/bin/env node
// afx-pack.mjs: rules for every AI tool. The free commands return VERDICTS; the rule TEXT comes from the vendor's server, only to a
// valid per-seat licence (afx-entitlement.mjs). Nothing readable is bundled in the free core beyond a short neutral starter.
//
//   afx rules check [--dir D] [--json]     FREE. Verdict only: each target file's rules block is OK, DRIFT (edited by hand or out of
//                                          date) or MISSING, by comparing a hash recorded in the block's marker. Prints no rule text.
//   afx rules render [--dir D] [--pack P] [--tool T]...   PRO. Fetches the pack from the server and writes each tool's file between
//                                          markers (<!-- afx:rules:begin pack=P sha=H --> ... end). Hand-written content outside the
//                                          markers is never touched. Exit 3 = not entitled, 4 = server problem.
// Server contract (the hub implements it; UNVERIFIED until it does):
//   GET {api}/api/cli/packs/{pack}?tool={tool}   Authorization: Bearer <licence token>   (api comes from the token's `api` claim)
//   200 {"pack":"generic-1","version":"1","files":[{"tool":"codex","path":"AGENTS.md","body":"..."}]}
//   401 invalid or expired token, 403 token lacks afx_cli:pro, others = server error.
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync, realpathSync } from "node:fs";
import { dirname, join, resolve, isAbsolute, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { entitlement, readToken, machineId, PRO_FEATURE } from "./afx-entitlement.mjs";
import { loadProject } from "./afx-project.mjs";

const isMain = () => { try { return !!process.argv[1] && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]); } catch { return false; } };
export const BEGIN = /<!-- afx:rules:begin pack=([\w.-]+) sha=([0-9a-f]{64}) -->/;
export const END = "<!-- afx:rules:end -->";
export const TARGETS = { "claude-code": "CLAUDE.md", cursor: ".cursor/rules/afx.mdc", copilot: ".github/copilot-instructions.md", codex: "AGENTS.md", replit: "replit.md", aider: "CONVENTIONS.md" };
export const sha256 = (s) => createHash("sha256").update(s).digest("hex");

export function wrap(pack, body) { const b = body.replace(/\s+$/, "") + "\n"; return `<!-- afx:rules:begin pack=${pack} sha=${sha256(b)} -->\n${b}${END}`; }

// verdict for one file's text: { state: "MISSING"|"OK"|"DRIFT", pack? }
export function blockVerdict(text) {
  const m = BEGIN.exec(text || "");
  if (!m) return { state: "MISSING" };
  const start = m.index + m[0].length + 1, end = text.indexOf(END, start);
  if (end < 0) return { state: "DRIFT", pack: m[1] };
  return { state: sha256(text.slice(start, end)) === m[2] ? "OK" : "DRIFT", pack: m[1] };
}

// Replace the marker block in `text` (or append one); everything outside the markers is preserved.
export function applyBlock(text, block) {
  const m = BEGIN.exec(text || "");
  if (!m) return (text ? text.replace(/\s*$/, "\n\n") : "") + block + "\n";
  const end = text.indexOf(END, m.index);
  if (end < 0) return text.slice(0, m.index) + block + "\n";
  return text.slice(0, m.index) + block + text.slice(end + END.length);
}

const safeRel = (p) => typeof p === "string" && p && !isAbsolute(p) && !normalize(p).startsWith("..") && !p.includes("\0");

export function check(dir, tools) {
  return tools.map((t) => {
    const rel = TARGETS[t]; const f = join(dir, rel);
    const v = existsSync(f) ? blockVerdict(readFileSync(f, "utf8")) : { state: "MISSING" };
    return { tool: t, file: rel, ...v };
  });
}

export async function render(dir, { pack, tools, env = process.env, fetchImpl = fetch } = {}) {
  const e = entitlement(PRO_FEATURE, { env });
  if (!e.entitled) return { code: 3, message: `afx rules render needs AFX CLI Pro: ${e.reason || e.state}. Free: afx rules check (verdicts only).` };
  const api = (e.payload.api || "").replace(/\/$/, "");
  if (!/^https?:\/\//.test(api)) return { code: 4, message: "the licence names no server (api claim missing)" };
  const token = readToken(env);
  const written = [];
  for (const tool of tools) {
    let res;
    try { res = await fetchImpl(`${api}/api/cli/packs/${encodeURIComponent(pack)}?tool=${encodeURIComponent(tool)}`, { headers: { Authorization: `Bearer ${token}`, "X-Afx-Machine": machineId() } }); }
    catch (x) { return { code: 4, message: `could not reach the licence server: ${x.message}` }; }
    if (res.status === 401 || res.status === 403) return { code: 3, message: `the server refused this licence (${res.status})` };
    if (!res.ok) return { code: 4, message: `server error ${res.status}` };
    let json; try { json = await res.json(); } catch { return { code: 4, message: "server sent an unreadable pack" }; }
    for (const f of json.files || []) {
      if (f.tool !== tool || !safeRel(f.path) || typeof f.body !== "string") return { code: 4, message: "server sent an unexpected file entry; nothing written for it" };
      const target = join(dir, f.path);
      mkdirSync(dirname(target), { recursive: true });
      writeFileSync(target, applyBlock(existsSync(target) ? readFileSync(target, "utf8") : "", wrap(json.pack || pack, f.body)));
      written.push(f.path);
    }
  }
  return { code: 0, message: `rules block written: ${written.join(", ") || "(none)"}`, written };
}

// PRO: re-render only the files whose block is DRIFT or MISSING (per the free check), one line per file.
export async function sync(dir, { pack, tools, env = process.env, fetchImpl = fetch } = {}) {
  const rows = check(dir, tools);
  const lines = rows.filter((r) => r.state === "OK").map((r) => `OK       ${r.file}`);
  const stale = rows.filter((r) => r.state !== "OK");
  if (!stale.length) return { code: 0, lines };
  const r = await render(dir, { pack, tools: stale.map((x) => x.tool), env, fetchImpl });
  if (r.code !== 0) return { code: r.code, lines, message: r.message };
  return { code: 0, lines: [...lines, ...stale.map((x) => `UPDATED  ${x.file}`)] };
}

export async function main(argv, { out = (s) => console.log(s), err = (s) => console.error(s), env = process.env, fetchImpl } = {}) {
  const [cmd, ...rest] = argv;
  const f = { dir: process.cwd(), tools: [], pack: "", json: false };
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === "--dir") f.dir = resolve(rest[++i] || ""); else if (a === "--pack") f.pack = rest[++i]; else if (a === "--tool") f.tools.push(rest[++i]); else if (a === "--json") f.json = true;
    else { err(`afx rules: unknown option ${a}`); return 2; }
  }
  const { config } = loadProject(f.dir);
  const tools = f.tools.length ? f.tools : config.tools;
  for (const t of tools) if (!TARGETS[t]) { err(`afx rules: unknown tool ${t} (known: ${Object.keys(TARGETS).join(", ")})`); return 2; }
  if (cmd === "check") {
    const rows = check(f.dir, tools);
    if (f.json) out(JSON.stringify(rows)); else for (const r of rows) out(`${r.state.padEnd(7)} ${r.file}${r.pack ? ` (pack ${r.pack})` : ""}`);
    return rows.every((r) => r.state === "OK") ? 0 : 1;
  }
  if (cmd === "render") {
    const r = await render(f.dir, { pack: f.pack || config.rules.pack, tools, env, fetchImpl });
    (r.code === 0 ? out : err)(r.message); return r.code;
  }
  if (cmd === "sync") {
    const r = await sync(f.dir, { pack: f.pack || config.rules.pack, tools, env, fetchImpl });
    for (const l of r.lines) out(l);
    if (r.code !== 0) err(r.message);
    return r.code;
  }
  err("usage: afx rules check [--dir D] [--json] | render|sync [--dir D] [--pack P] [--tool T]...");
  return 2;
}

if (isMain()) process.exit(await main(process.argv.slice(2)));
