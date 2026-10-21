#!/usr/bin/env node
// afx-fleet.mjs: this device and the whole fleet, from registry/fleet.json + ~/.claude/hooks/afx-guard/machine.conf.
// `afx fleet` prints it for people; `afx fleet --json` is the contract AFX Desktop's Machine/Fleet panel reads, so the
// GUI never parses the registry itself. Every section carries `error` (null when fine): a missing or unreadable file
// shows up as an error instead of a device silently disappearing.
//
//   node scripts/afx-guard/afx-fleet.mjs [--json] [--live]
//   AFX_MACHINE_CONF, AFX_HUB, AFX_REGISTRY_DIR override where it looks (the tests use them).
//
// fleet.json source, freshest first: the hub clone's origin/main (machine.conf hub=), then the registry folder next
// to this script (the copy afx-bootstrap.sh / the guard installer exported).
//
// --live (#16): adds `this.live` - THIS device's load1/ncpu/diskFreeGb/swapUsedGb/memSummary right now, via
// afx-live-load.sh --json. Only ever for "this" device: there is no central store of a machine's live state (see
// afx-live-load.sh's header for why), so a fleet-wide live view means querying each machine that's currently up,
// not reading one shared file. Off by default (adds a subprocess call) so plain `afx fleet` stays instant.

import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { join, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const FLEET_PATH = "scripts/afx-guard/registry/fleet.json";

export function readConf(file) {
  if (!existsSync(file)) return { values: {}, error: `missing ${file} (run afx-machine-conf.sh)` };
  try {
    const values = {};
    for (const line of readFileSync(file, "utf8").split(/\r?\n/)) {
      const m = line.match(/^([a-z_]+)=(.*)$/);
      if (m) values[m[1]] = m[2].trim().replace(/^~/, homedir());
    }
    return { values, error: null };
  } catch (e) {
    return { values: {}, error: `unreadable ${file}: ${e.message}` };
  }
}

function git(dir, ...args) {
  try { return execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 8000 }).trim(); } catch { return ""; }
}

// #16: this device's own live load, via afx-live-load.sh --json. Never for a remote
// device (see that script's header) - only "this" box can report its own live state.
function liveLoad() {
  try {
    const raw = execFileSync("bash", [join(HERE, "afx-live-load.sh"), "--json"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 8000 }).trim();
    return { ...JSON.parse(raw), error: null };
  } catch (e) {
    return { ts: null, os: null, load1: null, ncpu: null, diskFreeGb: null, swapUsedGb: null, memSummary: null, error: `afx-live-load.sh failed: ${e.message}` };
  }
}

export function loadFleet({ hub, registryDir }) {
  const tried = [];
  if (hub) {
    const raw = git(hub, "show", `origin/main:${FLEET_PATH}`);
    if (raw) {
      try { return { fleet: JSON.parse(raw), source: `hub origin/main ${git(hub, "rev-parse", "--short", "origin/main")}`, error: null }; }
      catch (e) { tried.push(`hub origin/main: invalid JSON (${e.message})`); }
    } else tried.push(`hub ${hub}: no ${FLEET_PATH} on origin/main`);
  }
  const file = join(registryDir, "fleet.json");
  if (existsSync(file)) {
    try { return { fleet: JSON.parse(readFileSync(file, "utf8")), source: `file ${file}`, error: null }; }
    catch (e) { tried.push(`${file}: invalid JSON (${e.message})`); }
  } else tried.push(`${file}: missing`);
  return { fleet: null, source: null, error: `fleet.json not found: ${tried.join("; ")}` };
}

export function buildFleet({ confFile, hub, registryDir, now = new Date(), live = false }) {
  const conf = readConf(confFile);
  const hubDir = hub || conf.values.hub || "";
  const { fleet, source, error } = loadFleet({ hub: hubDir, registryDir });
  const key = conf.values.registry || "";
  const devices = fleet?.devices || [];
  const me = devices.find((d) => d.key === key);
  // pathsFile is either a bare name (paths.lenovo-windows.json) or a repo path; only the registry folder is checked.
  const withErrors = devices.map((d) => {
    const pf = typeof d.pathsFile === "string" && d.pathsFile.endsWith(".json") ? basename(d.pathsFile) : "";
    const inHub = hubDir && git(hubDir, "ls-tree", "--name-only", "origin/main", `scripts/afx-guard/registry/${pf}`);
    const missing = pf && !existsSync(join(registryDir, pf)) && !inHub;
    return { ...d, error: missing ? `${pf} is not in the registry` : null };
  });
  return {
    generatedAt: now.toISOString(),
    this: {
      key: key || null,
      name: me?.name || conf.values.machine || null,
      ramGb: me?.ramGb ?? null,
      role: me?.role || null,
      heavyWork: me?.heavyWork || null,
      root: conf.values.root || null,
      hub: hubDir || null,
      error: conf.error || (!key ? "machine.conf has no registry= (afx-machine-conf.sh --machine <key>)" : !fleet ? error : !me ? `registry=${key} is not in fleet.json` : null),
      live: live ? liveLoad() : null,
    },
    devices: { items: withErrors, error: fleet ? null : error },
    virtual: { items: fleet?.virtual || [], error: fleet ? null : error },
    mcp: { items: fleet?.mcp || [], error: fleet ? null : error },
    source: { fleet: source, machineConf: confFile, updated: fleet?.updated || null },
  };
}

function human(f) {
  const t = f.this;
  const out = [];
  out.push(t.error ? `This device: ${t.name || "unknown"} (${t.error})` : `This device: ${t.name} (${t.ramGb} GB), registry=${t.key}`);
  if (t.role) out.push(`  role: ${t.role}`);
  if (t.heavyWork) out.push(`  heavy work: ${t.heavyWork}`);
  if (t.root) out.push(`  root: ${t.root}`);
  if (t.live) {
    out.push(t.live.error ? `  live: ${t.live.error}` : `  live: load1=${t.live.load1} ncpu=${t.live.ncpu} diskFreeGb=${t.live.diskFreeGb} swapUsedGb=${t.live.swapUsedGb ?? "?"} (${t.live.ts})`);
  }
  out.push("Fleet:");
  if (f.devices.error) out.push(`  ${f.devices.error}`);
  for (const d of f.devices.items) out.push(`  ${d.key === t.key ? "*" : " "} ${d.name.padEnd(20)} ${d.ramGb ? `${d.ramGb} GB`.padEnd(6) : "      "} ${d.kind}${d.error ? `  (${d.error})` : ""}`);
  for (const v of f.virtual.items) out.push(`    ${v.key.padEnd(20)} ${v.kind}: ${v.spec}`);
  out.push("MCPs:");
  for (const m of f.mcp.items) out.push(`    ${m.name}: ${m.where}`);
  out.push(`(fleet.json from ${f.source.fleet || "nowhere"}; updated ${f.source.updated || "?"})`);
  return out.join("\n");
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const f = buildFleet({
    confFile: process.env.AFX_MACHINE_CONF || join(homedir(), ".claude/hooks/afx-guard/machine.conf"),
    hub: process.env.AFX_HUB || "",
    registryDir: process.env.AFX_REGISTRY_DIR || join(HERE, "registry"),
    live: process.argv.includes("--live"),
  });
  process.stdout.write(process.argv.includes("--json") ? JSON.stringify(f, null, 2) + "\n" : human(f) + "\n");
}
