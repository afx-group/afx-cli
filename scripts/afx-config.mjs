#!/usr/bin/env node
// afx-config.mjs: the one place the AFX CLI reads its configuration. Core scripts ask this (or the bash reader
// afx_config_get in afx-platform.sh) instead of hard-coding an organisation, a hub repo or a folder.
//
// Resolution order (a config file only overrides the keys it sets):
//   1. $AFX_CONFIG                  explicit file (tests, CI)
//   2. ~/.afx/afx.config.json       written by `afx init`
//   3. afx-config.afx.json          the AFX preset, next to this script, ONLY if the file is present (private tier: a core
//                                   build does not contain it; AFX machines get it from the installer / bootstrap)
//   4. DEFAULTS below               neutral built-ins: no organisation, no hub repo, generic folders
//
//   node afx-config.mjs get <key>   print one value (paths stay unexpanded, "~/..."; arrays space-joined)
//   node afx-config.mjs dump        the merged config as JSON, plus where it came from
//   node afx-config.mjs path        the config file that is in effect (empty when built-in defaults)
//   node afx-config.mjs init [--org O] [--hub-repo O/R] [--root DIR] [--brand B] [--write] [--force]
//                                   the engine of `afx init`: prints the config it would write; --write writes it
// Schema: afx.config.schema.json. The bash fallbacks in afx-config-defaults.sh must equal DEFAULTS (a test checks it).
import { existsSync, mkdirSync, readFileSync, writeFileSync, realpathSync } from "node:fs";
const isMain = () => { try { return !!process.argv[1] && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]); } catch { return false; } }; // compare REAL paths: the installer links the folder, and a linked argv[1] never equals the real module path (macOS/Linux)
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Neutral built-ins: the free core knows no organisation. A tenant's values come from ~/.afx/afx.config.json (`afx init`)
// or, for AFX's own machines, from the private preset afx-config.afx.json. Keep afx-config-defaults.sh equal to this.
export const DEFAULTS = Object.freeze({
  org: "",
  hubRepo: "",
  extraOrgs: Object.freeze([]),
  clonesRootMac: "~/afx/clones",
  clonesRootWindows: "~/afx/clones",
  registryFile: "~/.afx/afx-projects.json",
  brand: "AFX CLI",
  quickstartDoc: "",
  enabledModules: "all",
  policyPacks: Object.freeze([]),
});

const HERE = dirname(fileURLToPath(import.meta.url));
export const PRESET_FILE = join(HERE, "afx-config.afx.json");

export const KEYS = Object.keys(DEFAULTS);
const STRING_KEYS = KEYS.filter((k) => typeof DEFAULTS[k] === "string" && k !== "enabledModules");

// $HOME wins over the OS home so Git Bash (HOME=/c/Users/x) and tests with a throwaway HOME agree with the bash reader.
export function userHome(env = process.env) { return env.HOME || env.USERPROFILE || homedir(); }

// The preset layer: the file next to this script when it exists (and AFX_NO_PRESET is not set). Never throws.
export function loadPreset({ env = process.env, file = PRESET_FILE } = {}) {
  if (env.AFX_NO_PRESET || !existsSync(file)) return null;
  try {
    const raw = JSON.parse(readFileSync(file, "utf8"));
    return validate(raw).length ? null : raw;
  } catch { return null; }
}

export function configPath(env = process.env, home = userHome(env)) {
  if (env.AFX_CONFIG) return env.AFX_CONFIG;
  return join(home, ".afx", "afx.config.json");
}

// Returns { config, source, error }. A missing file is not an error; an unreadable or invalid one is reported and the
// defaults are used, so a broken file never takes a machine's tooling down.
export function loadConfig({ env = process.env, home = userHome(env), presetFile = PRESET_FILE } = {}) {
  const file = configPath(env, home);
  const config = { ...DEFAULTS, policyPacks: [...DEFAULTS.policyPacks], extraOrgs: [...DEFAULTS.extraOrgs] };
  const preset = loadPreset({ env, file: presetFile });
  if (preset) for (const k of KEYS) if (preset[k] !== undefined) config[k] = Array.isArray(preset[k]) ? [...preset[k]] : preset[k];
  const base = "defaults"; // the preset counts as built-in: only a user file changes the source
  if (!existsSync(file)) return { config, source: base, error: null };
  try {
    const raw = JSON.parse(readFileSync(file, "utf8"));
    const problems = validate(raw);
    if (problems.length) return { config, source: base, error: `${file}: ${problems.join("; ")}` };
    for (const k of KEYS) if (raw[k] !== undefined) config[k] = raw[k];
    return { config, source: file, error: null };
  } catch (e) {
    return { config, source: base, error: `${file}: ${e.message}` };
  }
}

export function validate(raw) {
  const problems = [];
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return ["must be a JSON object"];
  for (const k of Object.keys(raw)) {
    if (k === "$schema" || k === "version") continue;
    if (!KEYS.includes(k)) { problems.push(`unknown key ${k}`); continue; }
    if (STRING_KEYS.includes(k)) {
      if (typeof raw[k] !== "string" || !raw[k].trim()) problems.push(`${k} must be a non-empty string`);
    } else if (k === "enabledModules") {
      if (!(raw[k] === "all" || (Array.isArray(raw[k]) && raw[k].every((x) => typeof x === "string")))) problems.push('enabledModules must be "all" or an array of module names');
    } else if (k === "policyPacks" || k === "extraOrgs") {
      if (!(Array.isArray(raw[k]) && raw[k].every((x) => typeof x === "string"))) problems.push(`${k} must be an array of strings`);
    }
  }
  if (typeof raw.hubRepo === "string" && !/^[^/\s]+\/[^/\s]+$/.test(raw.hubRepo)) problems.push("hubRepo must look like owner/repo");
  return problems;
}

export function expandHome(p, home = userHome()) {
  return typeof p === "string" ? p.replace(/^~(?=$|[\\/])/, home) : p;
}

export function format(v) { return Array.isArray(v) ? v.join(" ") : String(v); }

// `afx init`: build a config from flags (or prompts on a terminal), print it, and write it only with --write.
export function buildInit(flags) {
  const out = { version: 1 };
  if (flags.org) out.org = flags.org;
  if (flags["hub-repo"]) out.hubRepo = flags["hub-repo"];

  if (flags.root) { out.clonesRootMac = flags.root; out.clonesRootWindows = flags.root; }
  if (flags.brand) out.brand = flags.brand;
  return out;
}

async function prompt(flags) {
  const { createInterface } = await import("node:readline/promises");
  const rl = createInterface({ input: process.stdin, output: process.stderr });
  const ask = async (label, def) => ((await rl.question(`${label} [${def}]: `)).trim() || def);
  flags.org = flags.org || (await ask("GitHub org", DEFAULTS.org || "my-org"));
  flags["hub-repo"] = flags["hub-repo"] || (await ask("Hub repo (owner/repo, blank for none)", ""));
  flags.root = flags.root || (await ask("Clones root", DEFAULTS.clonesRootWindows));
  rl.close();
}

async function init(argv, env = process.env, home = userHome(env)) {
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) { console.error(`afx init: unexpected argument ${a}`); return 2; }
    const k = a.slice(2);
    if (["write", "force", "yes"].includes(k)) flags[k] = true;
    else if (["org", "hub-repo", "root", "brand"].includes(k)) { flags[k] = argv[++i]; if (!flags[k]) { console.error(`afx init: --${k} needs a value`); return 2; } }
    else { console.error(`afx init: unknown option ${a}`); return 2; }
  }
  const given = flags.org || flags["hub-repo"] || flags.root;
  if (!given && !flags.yes && process.stdin.isTTY && process.stdout.isTTY) await prompt(flags);
  const cfg = buildInit(flags);
  const problems = validate(cfg);
  if (problems.length) { console.error(`afx init: ${problems.join("; ")}`); return 2; }
  const file = configPath(env, home);
  console.log(JSON.stringify(cfg, null, 2));
  if (!flags.write) { console.error(`afx init: dry run. Would write ${file}. Add --write to save it.`); return 0; }
  if (existsSync(file) && !flags.force) { console.error(`afx init: ${file} already exists; nothing written (--force to replace it).`); return 1; }
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n");
  console.error(`afx init: wrote ${file}`);
  return 0;
}

if (isMain()) {
  const [cmd, key] = process.argv.slice(2);
  if (cmd === "init") process.exit(await init(process.argv.slice(3)));
  const { config, source, error } = loadConfig();
  if (error) console.error(`afx-config: ${error} (using built-in defaults)`);
  if (cmd === "get") {
    if (!KEYS.includes(key)) { console.error(`afx-config: unknown key ${key || "(none)"}; keys: ${KEYS.join(", ")}`); process.exit(2); }
    console.log(format(config[key]));
  } else if (cmd === "dump") {
    console.log(JSON.stringify({ source, config }, null, 2));
  } else if (cmd === "path") {
    console.log(source === "defaults" ? "" : source);
  } else {
    console.error("usage: afx-config.mjs get <key> | dump | path | init [flags]");
    process.exit(2);
  }
}
