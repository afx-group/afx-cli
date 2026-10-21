# AFX CLI

AFX CLI is one front door to set up and govern AI coding agents (Claude Code, Cursor, Codex, GitHub Copilot, Replit Agent, Ollama-based agents) across a team's machines. It gives every agent the same rules, the same guard hooks and the same safe git workflow, and gives you one command (`afx`) to see where you are, what is on this machine and which fleet it belongs to.

Status: **early release 0.1.x**. Expect rough edges and changes between minor versions.

## Install

| Method | Status |
| --- | --- |
| `curl` installer (`install.sh`) | available |
| npm: `npm i -g afx-cli` (needs Node.js 18+ and bash; on Windows, Git for Windows) | available |
| Homebrew: `brew install afx-group/afx/afx-cli` | planned |
| winget | planned |

The installer downloads a release of this repository, verifies its SHA-256 checksum, unpacks it under `~/.afx` and writes a wrapper at `~/.afx/bin/afx`. It never edits your shell profile; it prints the PATH line to add.

```sh
curl -fsSL https://raw.githubusercontent.com/afx-group/afx-cli/main/install.sh | sh
```

Environment overrides: `AFX_CLI_VERSION` (default: latest release), `AFX_HOME` (default `~/.afx`), `AFX_CLI_REPO` (default `afx-group/afx-cli`). Re-running the installer upgrades and keeps older version folders.

## Quick start

```sh
afx init --org my-org --hub-repo my-org/my-hub --write   # write ~/.afx/afx.config.json (omit --write for a dry run)
afx          # this device, plus a numbered menu on a terminal
afx brief    # a briefing any agent can read first
afx where    # is this folder an approved place to work?
afx fleet    # this device and the fleet
afx help
```

## Configuration

`afx` reads `afx.config.json` (the file named by `$AFX_CONFIG`, else `~/.afx/afx.config.json`). Without one, neutral built-in defaults apply. `afx init` prints a config (dry run) or saves it with `--write`. The schema is `scripts/afx.config.schema.json`.

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
