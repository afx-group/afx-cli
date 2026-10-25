# AFX CLI

AFX CLI is one front door to set up and govern AI coding agents (Claude Code, Cursor, Codex, GitHub Copilot, Replit Agent, Ollama-based agents) across a team's machines. It gives every agent the same rules, the same guard hooks and the same safe git workflow, and gives you one command (`afx`) to see where you are, what is on this machine and which fleet it belongs to.

Status: **early release 0.1.x** (0.1.0 to 0.1.2 are published on npm; the commands `doctor`, `init --project`, `project`, `rules`, `license`, `guard` and `mcp` described below are in the source tree and ship with the next release, they are not in 0.1.2). Expect rough edges and changes between minor versions.

## Install

| Method | Status |
| --- | --- |
| `curl` installer (`install.sh`) | `install.sh` is on the repo's main branch; the route was not re-run on 2026-10-25 |
| npm: `npm i -g afx-cli` (needs Node.js 18+ and bash; on Windows, Git for Windows) | published: 0.1.2 on npm (installed and run in a sandbox on 2026-10-25) |
| Homebrew: `brew install afx-group/afx/afx-cli` (macOS/Linux; if you also use the curl installer, check `which -a afx` so only one `afx` comes first on PATH) | tap and formula exist; route not re-run on 2026-10-25 |
| winget | not planned (needs a compiled launcher; on Windows use npm or the installer with Git for Windows) |

The installer downloads a release of this repository, verifies its SHA-256 checksum, unpacks it under `~/.afx` and writes a wrapper at `~/.afx/bin/afx`. It never edits your shell profile; it prints the PATH line to add.

```sh
curl -fsSL https://raw.githubusercontent.com/afx-group/afx-cli/main/install.sh | sh
```

Environment overrides: `AFX_CLI_VERSION` (default: latest release), `AFX_HOME` (default `~/.afx`), `AFX_CLI_REPO` (default `afx-group/afx-cli`). Re-running the installer upgrades and keeps older version folders.

## Quick start

```sh
afx init --project --write      # in your repo: detect branch, package manager and gate command, write ./afx.config.json (omit --write for a dry run)
afx doctor                      # check node, git, the project config, the gate command and the package manager; exit 0 = ok
afx init --org my-org --write   # optional: machine-level settings in ~/.afx/afx.config.json
afx          # this device, plus a numbered menu on a terminal
afx brief    # a briefing any agent can read first
afx where    # is this folder an approved place to work?
afx fleet    # this device and the fleet
afx help
```

## Configuration

Two files, both optional, both written by `afx init` (dry run unless `--write`):

- **Project file** `<repo>/afx.config.json` (commit it): default branch, package manager, the merge gate command, protected paths, which AI tools you use. `afx init --project` detects these. `afx doctor` validates it; `afx project dump` shows the merged result; `afx brief` prints rules derived from it.
- **Machine file** `~/.afx/afx.config.json` (or the file named by `$AFX_CONFIG`): organisation, hub repo, clones folder. The schema is `scripts/afx.config.schema.json`.

Without either, neutral built-in defaults apply.

## What is in Core and what is Pro

**Core** (this repository, free, Apache-2.0): the `afx` front door, configuration, location and workspace guards, policy guard hooks and their installer, one rules template rendered for every AI tool, worktree discipline tools, the gate and land workflow, and repo hygiene lints.

**AFX CLI Pro** (commercial, per seat): multi-machine control plane, remote builds and ops on cloud VMs, health and baseline gates, conformance packs, unattended-run control plane, and mobile ship tooling. Pro is not in this repository. See https://allforxproject.com/products/afx-cli

## Requirements

- bash 3.2 or newer, git, curl, tar
- Node.js 18 or newer for configuration (`afx init`) and `afx fleet`
- Windows: Git for Windows (Git Bash). `afx` runs through Git Bash.

## License and trademarks

Apache License 2.0, see `LICENSE` and `NOTICE`. "AFX" and "#AllForX" are trademarks of AFX Holdings and are not licensed by the Apache License 2.0.

## Contributing

This repository is generated from AFX's source of truth on each release. Issues are welcome. Pull requests are reviewed, and accepted changes are applied in the source and arrive here in the next release.
