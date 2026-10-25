#!/usr/bin/env node
// afx-project.mjs: the project-level configuration of the AFX CLI (<repo>/afx.config.json, committed, shared by the team).
// The user/machine file (~/.afx/afx.config.json, afx-config.mjs) says where things live on one machine; this file says how
// one project works: default branch, package manager, the merge gate, protected paths, which AI tools get a rules file.
// Everything is optional; defaults are neutral (no organisation, no host names). Plan: artifacts/afx-website/docs/toolkit-productization/GENERIC_CONFIG_PLAN.md
//
//   node afx-project.mjs init [--dir D] [--gate CMD] [--branch B] [--pm P] [--name N] [--yes] [--write] [--force]
//                                  detect the project's settings, print the file; --write saves <dir>/afx.config.json
//   node afx-project.mjs get <dotted.key> [--dir D]    one value (arrays space-joined; defaults applied)
//   node afx-project.mjs dump [--dir D]                the merged project config as JSON
//   node afx-project.mjs doctor [--dir D] [--json]     check the install; exit 0 no FAIL, 1 any FAIL, 2 usage
//   node afx-project.mjs brief-rules [--dir D]         the "rules every agent follows" lines derived from this project's config
import { existsSync, readFileSync, writeFileSync, realpathSync, readdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const isMain = () => { try { return !!process.argv[1] && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]); } catch { return false; } };

export const FILE = "afx.config.json";
export const PACKAGE_MANAGERS = ["pnpm", "npm", "yarn", "bun"];
export const TOOLS = ["claude-code", "cursor", "copilot", "codex", "replit", "aider"];
export const LAND_METHODS = ["merge-commit", "squash", "rebase"];
export const MODEL_CLASSES = ["low", "mid", "high"];

// Neutral built-ins (a project file only overrides what it sets, one level deep per section).
export const DEFAULTS = Object.freeze({
  version: 2,
  project: { name: "", kind: "single" },
  git: {
    defaultBranch: "main", branchPrefix: "work/", protectedBranchPrefixes: ["rescue/", "preserve/", "archive/"],
    worktreeDir: ".worktrees", requireWorktree: true, landMethod: "merge-commit", prLabelOwnerOk: "owner-ok",
  },
  packageManager: "npm",
  gate: { command: "", docsOnlyGlobs: ["**/*.md", "docs/**"], timeoutMinutes: 30, slots: 3, ratchetBaseline: ".afx/ratchet-baseline.json" },
  protectedPaths: [],
  hardStops: { massDeleteFiles: 200, secretScan: true, destructiveSql: true },
  heavyCommands: [],
  tools: ["claude-code"],
  rules: { pack: "generic-1", overrides: {}, extra: [] },
  modelPolicy: { default: "mid", mechanicalWork: "low", highRequiresApproval: true, approver: "", weeklyBudgetWarnPercents: [50, 75, 90], subagentConcurrencyMax: 4 },
  controlPlane: { statusDir: ".afx/status", shipQueueFile: ".afx/ship-queue.json", windowHours: 5 },
  design: { docsDir: "docs/design", apps: [], mockupApprover: "", parityPairs: [] },
  claims: { ledger: "docs/RELEASE_CLAIMS.md", evidenceDir: "docs/evidence" },
});

const SECTIONS = Object.keys(DEFAULTS).filter((k) => DEFAULTS[k] && typeof DEFAULTS[k] === "object" && !Array.isArray(DEFAULTS[k]));
const TOP_KEYS = new Set(["$schema", ...Object.keys(DEFAULTS)]);

const isStrArr = (v) => Array.isArray(v) && v.every((x) => typeof x === "string");
const isObj = (v) => v && typeof v === "object" && !Array.isArray(v);

// Returns a list of problems ([] = valid). Unknown keys are problems at every level (typos must not pass silently).
export function validate(raw) {
  const p = [];
  if (!isObj(raw)) return ["must be a JSON object"];
  for (const k of Object.keys(raw)) if (!TOP_KEYS.has(k)) p.push(`unknown key ${k}`);
  if (raw.version !== undefined && raw.version !== 2) p.push("version must be 2");
  for (const s of SECTIONS) {
    if (raw[s] === undefined) continue;
    if (!isObj(raw[s])) { p.push(`${s} must be an object`); continue; }
    for (const k of Object.keys(raw[s])) if (!(k in DEFAULTS[s])) p.push(`unknown key ${s}.${k}`);
  }
  const str = (path, v, { empty = false } = {}) => { if (v !== undefined && (typeof v !== "string" || (!empty && !v.trim()))) p.push(`${path} must be a${empty ? "" : " non-empty"} string`); };
  const bool = (path, v) => { if (v !== undefined && typeof v !== "boolean") p.push(`${path} must be true or false`); };
  const num = (path, v, min = 0) => { if (v !== undefined && !(Number.isFinite(v) && v >= min)) p.push(`${path} must be a number >= ${min}`); };
  const arr = (path, v) => { if (v !== undefined && !isStrArr(v)) p.push(`${path} must be an array of strings`); };
  const oneOf = (path, v, list) => { if (v !== undefined && !list.includes(v)) p.push(`${path} must be one of ${list.join(", ")}`); };
  const g = raw.git || {}, gt = raw.gate || {}, mp = raw.modelPolicy || {}, cp = raw.controlPlane || {}, hs = raw.hardStops || {};
  str("project.name", raw.project?.name, { empty: true }); oneOf("project.kind", raw.project?.kind, ["single", "monorepo", "multi-repo"]);
  str("git.defaultBranch", g.defaultBranch); str("git.branchPrefix", g.branchPrefix, { empty: true }); arr("git.protectedBranchPrefixes", g.protectedBranchPrefixes);
  str("git.worktreeDir", g.worktreeDir, { empty: true }); bool("git.requireWorktree", g.requireWorktree); oneOf("git.landMethod", g.landMethod, LAND_METHODS); str("git.prLabelOwnerOk", g.prLabelOwnerOk);
  if (typeof g.defaultBranch === "string" && /[\s~^:?*\[\\]/.test(g.defaultBranch)) p.push("git.defaultBranch is not a valid branch name");
  if (typeof g.worktreeDir === "string" && (g.worktreeDir.startsWith("/") || g.worktreeDir.includes(".."))) p.push("git.worktreeDir must be repo-relative");
  oneOf("packageManager", raw.packageManager, PACKAGE_MANAGERS);
  str("gate.command", gt.command, { empty: true }); arr("gate.docsOnlyGlobs", gt.docsOnlyGlobs); num("gate.timeoutMinutes", gt.timeoutMinutes, 1); num("gate.slots", gt.slots, 1); str("gate.ratchetBaseline", gt.ratchetBaseline);
  arr("protectedPaths", raw.protectedPaths); arr("heavyCommands", raw.heavyCommands);
  num("hardStops.massDeleteFiles", hs.massDeleteFiles, 1); bool("hardStops.secretScan", hs.secretScan); bool("hardStops.destructiveSql", hs.destructiveSql);
  if (raw.tools !== undefined) { if (!isStrArr(raw.tools)) p.push("tools must be an array of strings"); else for (const t of raw.tools) if (!TOOLS.includes(t)) p.push(`tools: unknown tool ${t} (known: ${TOOLS.join(", ")})`); }
  str("rules.pack", raw.rules?.pack); arr("rules.extra", raw.rules?.extra);
  if (raw.rules?.overrides !== undefined && !isObj(raw.rules.overrides)) p.push("rules.overrides must be an object");
  oneOf("modelPolicy.default", mp.default, MODEL_CLASSES); oneOf("modelPolicy.mechanicalWork", mp.mechanicalWork, MODEL_CLASSES); bool("modelPolicy.highRequiresApproval", mp.highRequiresApproval);
  str("modelPolicy.approver", mp.approver, { empty: true }); num("modelPolicy.subagentConcurrencyMax", mp.subagentConcurrencyMax, 1);
  if (mp.weeklyBudgetWarnPercents !== undefined && !(Array.isArray(mp.weeklyBudgetWarnPercents) && mp.weeklyBudgetWarnPercents.every((n) => Number.isFinite(n) && n > 0 && n <= 100))) p.push("modelPolicy.weeklyBudgetWarnPercents must be numbers in (0,100]");
  str("controlPlane.statusDir", cp.statusDir); str("controlPlane.shipQueueFile", cp.shipQueueFile); num("controlPlane.windowHours", cp.windowHours, 1);
  for (const [path, v] of [["controlPlane.statusDir", cp.statusDir], ["controlPlane.shipQueueFile", cp.shipQueueFile], ["design.docsDir", raw.design?.docsDir], ["claims.ledger", raw.claims?.ledger], ["claims.evidenceDir", raw.claims?.evidenceDir], ["gate.ratchetBaseline", gt.ratchetBaseline]])
    if (typeof v === "string" && (v.startsWith("/") || v.includes(".."))) p.push(`${path} must be repo-relative`);
  str("design.docsDir", raw.design?.docsDir); arr("design.apps", raw.design?.apps); str("design.mockupApprover", raw.design?.mockupApprover, { empty: true });
  if (raw.design?.parityPairs !== undefined && !(Array.isArray(raw.design.parityPairs) && raw.design.parityPairs.every((x) => isStrArr(x) && x.length === 2))) p.push("design.parityPairs must be an array of [a, b] pairs");
  str("claims.ledger", raw.claims?.ledger); str("claims.evidenceDir", raw.claims?.evidenceDir);
  return p;
}

const clone = (v) => JSON.parse(JSON.stringify(v));
export function merge(raw) {
  const out = clone(DEFAULTS);
  for (const k of Object.keys(raw || {})) {
    if (k === "$schema") continue;
    if (SECTIONS.includes(k) && isObj(raw[k])) out[k] = { ...out[k], ...clone(raw[k]) };
    else out[k] = clone(raw[k]);
  }
  return out;
}

// Walk up from dir to the folder holding afx.config.json (stops at the filesystem root). Returns the file path or "".
export function findFile(dir) {
  let d = resolve(dir);
  for (;;) {
    const f = join(d, FILE);
    if (existsSync(f)) return f;
    const up = dirname(d);
    if (up === d) return "";
    d = up;
  }
}

export function loadProject(dir = process.cwd()) {
  const file = findFile(dir);
  if (!file) return { config: merge({}), file: "", root: resolve(dir), error: null };
  try {
    const raw = JSON.parse(readFileSync(file, "utf8"));
    const problems = validate(raw);
    if (problems.length) return { config: merge({}), file, root: dirname(file), error: `${file}: ${problems.join("; ")}` };
    return { config: merge(raw), file, root: dirname(file), error: null };
  } catch (e) { return { config: merge({}), file, root: dirname(file), error: `${file}: ${e.message}` }; }
}

export function getPath(obj, dotted) {
  let v = obj;
  for (const part of dotted.split(".")) { if (!isObj(v) || !(part in v)) return undefined; v = v[part]; }
  return v;
}
const fmt = (v) => (Array.isArray(v) ? v.join(" ") : isObj(v) ? JSON.stringify(v) : String(v));

// ---- detection (used by init) -------------------------------------------------------------------------------------
const git = (dir, ...a) => { try { return execFileSync("git", ["-C", dir, ...a], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 5000 }).trim(); } catch { return ""; } };

export function detectPackageManager(dir) {
  if (existsSync(join(dir, "pnpm-lock.yaml")) || existsSync(join(dir, "pnpm-workspace.yaml"))) return "pnpm";
  if (existsSync(join(dir, "yarn.lock"))) return "yarn";
  if (existsSync(join(dir, "bun.lockb")) || existsSync(join(dir, "bun.lock"))) return "bun";
  if (existsSync(join(dir, "package-lock.json"))) return "npm";
  // No lockfile yet (a fresh project): the package.json `packageManager` field, else npm (what Node ships) when there is a package.json.
  try {
    const pj = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
    const declared = String(pj.packageManager || "").split("@")[0];
    return PACKAGE_MANAGERS.includes(declared) ? declared : "npm";
  } catch { return ""; }
}
export function detectBranch(dir) {
  const head = git(dir, "symbolic-ref", "--short", "refs/remotes/origin/HEAD");
  if (head) return head.replace(/^origin\//, "");
  return git(dir, "branch", "--show-current") || "";
}
export function detectGate(dir, pm) {
  let scripts = {};
  try { scripts = JSON.parse(readFileSync(join(dir, "package.json"), "utf8")).scripts || {}; } catch { return ""; }
  const run = (s) => (pm === "yarn" ? `yarn ${s}` : pm === "bun" ? `bun run ${s}` : `${pm} run ${s}`);
  const picks = ["typecheck", "lint", "test"].filter((s) => scripts[s]);
  return picks.map(run).join(" && ");
}
export function detectKind(dir) {
  return existsSync(join(dir, "pnpm-workspace.yaml")) || existsSync(join(dir, "turbo.json")) || existsSync(join(dir, "lerna.json")) || existsSync(join(dir, "nx.json")) ? "monorepo" : "single";
}
export function detectProtected(dir) {
  const out = [];
  for (const [probe, glob] of [["migrations", "migrations/**"], ["drizzle", "drizzle/**"], ["prisma/migrations", "prisma/migrations/**"], [".github/workflows", ".github/workflows/**"], ["infra", "infra/**"], ["terraform", "terraform/**"]])
    if (existsSync(join(dir, probe))) out.push(glob);
  out.push("**/.env*");
  return out;
}
export function detectTools(dir) {
  const t = ["claude-code"];
  if (existsSync(join(dir, ".cursor")) || existsSync(join(dir, ".cursorrules"))) t.push("cursor");
  if (existsSync(join(dir, ".github", "copilot-instructions.md"))) t.push("copilot");
  if (existsSync(join(dir, "AGENTS.md"))) t.push("codex");
  if (existsSync(join(dir, "replit.md")) || existsSync(join(dir, ".replit"))) t.push("replit");
  if (existsSync(join(dir, "CONVENTIONS.md")) || existsSync(join(dir, ".aider.conf.yml"))) t.push("aider");
  return t;
}
export function heavyFor(pm) {
  const run = (s) => (pm === "yarn" ? `yarn ${s}` : `${pm} run ${s}`);
  const inst = pm === "yarn" ? "yarn install" : `${pm} install`;
  return [inst, run("build"), run("test"), "tsc"];
}

export function buildInit(dir, flags = {}) {
  const pm = flags.pm || detectPackageManager(dir) || "";
  const out = { version: 2 };
  out.project = { name: flags.name || dirnameOf(dir), kind: detectKind(dir) };
  const branch = flags.branch || detectBranch(dir);
  if (branch) out.git = { defaultBranch: branch };
  if (pm) { out.packageManager = pm; out.heavyCommands = heavyFor(pm); }
  const gate = flags.gate || (pm ? detectGate(dir, pm) : "");
  if (gate) out.gate = { command: gate };
  out.protectedPaths = detectProtected(dir);
  out.tools = detectTools(dir);
  return out;
}
const dirnameOf = (d) => resolve(d).split(/[\\/]/).pop();

// ---- doctor ----------------------------------------------------------------------------------------------------
const onPath = (bin, env = process.env) => (env.PATH || "").split(process.platform === "win32" ? ";" : ":").some((d) => d && existsSync(join(d, bin)));

export function doctor(dir, { env = process.env } = {}) {
  const rows = [];
  const add = (level, check, detail) => rows.push({ level, check, detail });
  const major = Number(process.versions.node.split(".")[0]);
  add(major >= 18 ? "PASS" : "FAIL", "node >= 18", `node ${process.versions.node}`);
  const top = git(dir, "rev-parse", "--show-toplevel");
  add(top ? "PASS" : "FAIL", "inside a git repository", top || `${resolve(dir)} is not in a git repository`);
  const { config, file, error } = loadProject(dir);
  if (!file) add("FAIL", "project config", `no ${FILE} found from ${resolve(dir)} upward (run: afx init --project --write)`);
  else if (error) add("FAIL", "project config", error);
  else add("PASS", "project config", file);
  if (file && !error) {
    const root = dirname(file);
    const br = config.git.defaultBranch;
    const hasBranch = top && (git(root, "rev-parse", "--verify", "--quiet", `refs/heads/${br}`) || git(root, "rev-parse", "--verify", "--quiet", `refs/remotes/origin/${br}`));
    add(!top ? "WARN" : hasBranch ? "PASS" : "WARN", "default branch exists", hasBranch ? br : `${br} not found locally or on origin (yet)`);
    const pm = config.packageManager;
    add(onPath(pm, env) ? "PASS" : "WARN", `package manager "${pm}" on PATH`, onPath(pm, env) ? pm : `${pm} not found on PATH`);
    const gate = config.gate.command;
    if (!gate.trim()) add("FAIL", "merge gate configured", "gate.command is empty: no gate, no merge (set it in " + FILE + ")");
    else {
      const first = gate.trim().split(/\s+/)[0];
      add(onPath(first, env) || existsSync(join(root, first)) ? "PASS" : "WARN", "gate command resolvable", `${first} (full: ${gate})`);
    }
    add(config.tools.length ? "PASS" : "WARN", "AI tools listed", config.tools.join(", ") || "none");
    const ignored = existsSync(join(root, ".gitignore")) && readFileSync(join(root, ".gitignore"), "utf8").split(/\r?\n/).some((l) => l.replace(/\/$/, "") === config.git.worktreeDir.replace(/\/$/, ""));
    add(!config.git.requireWorktree || ignored ? "PASS" : "WARN", `worktree folder ${config.git.worktreeDir} is git-ignored`, ignored ? "yes" : `add "${config.git.worktreeDir}/" to .gitignore`);
  }
  return rows;
}

// Lines for `afx brief`, derived from the project's config. Neutral wording; values come from the file.
export function briefRules(config) {
  const g = config.git, pm = config.packageManager;
  const lines = [];
  lines.push(g.requireWorktree
    ? `- Edit only in a git worktree under ${g.worktreeDir}/<name> on a ${g.branchPrefix}<topic> branch; never directly on ${g.defaultBranch}.`
    : `- Work on a ${g.branchPrefix}<topic> branch; never directly on ${g.defaultBranch}.`);
  lines.push("- Uncommitted work you did not make belongs to someone else: never restore, reset, clean or stash it.");
  lines.push(`- Done means merged: land with afx land (${g.landMethod}), then remove the worktree. Push before ending a session.`);
  lines.push(`- Use ${pm} only; no force-push; no direct push to ${g.defaultBranch}; report real exit codes; no fabricated data.`);
  if (config.gate.command) lines.push(`- The merge gate is: ${config.gate.command} (its literal exit code goes in the PR).`);
  if (config.protectedPaths.length) lines.push(`- Protected paths need explicit approval (label ${g.prLabelOwnerOk}): ${config.protectedPaths.join(", ")}.`);
  lines.push("- A guard block is the rule working: ask the owner, never route around it.");
  return lines;
}

// ---- CLI --------------------------------------------------------------------------------------------------------
function parse(argv, valued, bools) {
  const f = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) { f._.push(a); continue; }
    const k = a.slice(2);
    if (bools.includes(k)) f[k] = true;
    else if (valued.includes(k)) { f[k] = argv[++i]; if (f[k] === undefined) throw new Error(`--${k} needs a value`); }
    else throw new Error(`unknown option ${a}`);
  }
  return f;
}

export function main(argv, { out = (s) => console.log(s), err = (s) => console.error(s) } = {}) {
  const cmd = argv[0];
  let f;
  try { f = parse(argv.slice(1), ["dir", "gate", "branch", "pm", "name"], ["yes", "write", "force", "json", "project"]); } catch (e) { err(`afx-project: ${e.message}`); return 2; }
  const dir = resolve(f.dir || process.cwd());
  if (cmd === "init") {
    if (f.pm && !PACKAGE_MANAGERS.includes(f.pm)) { err(`afx init: --pm must be one of ${PACKAGE_MANAGERS.join(", ")}`); return 2; }
    const cfg = buildInit(dir, f);
    const problems = validate(cfg);
    if (problems.length) { err(`afx init: ${problems.join("; ")}`); return 2; }
    const file = join(dir, FILE);
    out(JSON.stringify(cfg, null, 2));
    if (!cfg.gate) err("afx init: no gate command detected (no typecheck, lint or test script). Set one with --gate '<command>': without a gate there is no merge.");
    if (!f.write) { err(`afx init: dry run. Would write ${file}. Add --write to save it.`); return 0; }
    if (existsSync(file) && !f.force) { err(`afx init: ${file} already exists; nothing written (--force to replace it).`); return 1; }
    writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n");
    err(`afx init: wrote ${file}. Next: afx doctor`);
    return 0;
  }
  const { config, file, error } = loadProject(dir);
  if (cmd === "doctor") {
    const rows = doctor(dir);
    if (f.json) out(JSON.stringify(rows, null, 2));
    else for (const r of rows) out(`${r.level.padEnd(4)}  ${r.check}: ${r.detail}`);
    const fails = rows.filter((r) => r.level === "FAIL").length;
    if (!f.json) out(fails ? `afx doctor: ${fails} problem(s) to fix` : `afx doctor: ok (${rows.filter((r) => r.level === "WARN").length} warning(s))`);
    return fails ? 1 : 0;
  }
  if (error) err(`afx-project: ${error} (using built-in defaults)`);
  if (cmd === "get") {
    const key = f._[0];
    const v = key && getPath(config, key);
    if (v === undefined) { err(`afx-project: unknown key ${key || "(none)"}`); return 2; }
    out(fmt(v)); return 0;
  }
  if (cmd === "dump") { out(JSON.stringify({ source: file || "defaults", config }, null, 2)); return 0; }
  if (cmd === "brief-rules") { for (const l of briefRules(config)) out(l); return file && !error ? 0 : 3; }
  err("usage: afx-project.mjs init|get <key>|dump|doctor|brief-rules [--dir D]");
  return 2;
}

if (isMain()) process.exit(main(process.argv.slice(2)));
