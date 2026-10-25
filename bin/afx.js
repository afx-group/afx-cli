#!/usr/bin/env node
// npm launcher for AFX CLI: runs the bundled scripts/afx with bash and forwards the exit code.
"use strict";
const { spawnSync } = require("node:child_process");
const { existsSync } = require("node:fs");
const path = require("node:path");

const scripts = path.resolve(__dirname, "..", "scripts");
const entry = path.join(scripts, "afx");
const fwd = (p) => p.split(path.sep).join("/");

function findBash() {
  if (process.platform === "win32") {
    const gitBash = "C:\\Program Files\\Git\\bin\\bash.exe";
    if (existsSync(gitBash)) return gitBash;
  }
  const probe = spawnSync("bash", ["--version"], { stdio: "ignore" });
  return probe.error ? null : "bash";
}

const bash = findBash();
if (!bash) {
  console.error("afx: bash was not found. AFX CLI needs bash 3.2+ (on Windows install Git for Windows, which provides Git Bash).");
  process.exit(127);
}
if (!existsSync(entry)) {
  console.error("afx: bundled script missing: " + entry);
  process.exit(2);
}
const r = spawnSync(bash, [fwd(entry), ...process.argv.slice(2)], {
  stdio: "inherit",
  env: { ...process.env, AFX_GUARD_DIR: fwd(scripts) },
});
if (r.error) {
  console.error("afx: could not run bash: " + r.error.message);
  process.exit(127);
}
process.exit(r.status === null ? 1 : r.status);
