# Windows-side process tooling (a Windows PC) — not previously in git

Inventory taken 2026-09-27 from the Lenovo Windows PC, for the Mac/Linux parity effort
(portable guard scripts + Windows equivalents). This directory holds copies of what
exists; the live originals stay machine-local at `C:\Users\you\Projects\`.

## 1. Session launcher: `afx-terminal-agent-launcher.ps1` (older launcher names are forwarding shims on machines that had them)

The one way sessions are supposed to start on this machine. Copied verbatim in this
directory. Behavior:
- Reads `afx-projects.json` (schema below) as the single source of truth for every
  project's canonical path.
- Before opening anything: verifies the canonical path has a `.git` dir, verifies
  `origin`'s remote URL actually matches the expected `owner/repo` slug (catches a wrong
  clone in the right-looking folder), fetches (never pulls), and prints unpushed
  commits / uncommitted files / stashes / extra worktrees / ahead-behind vs the
  project's target branch (staging if it has one, else default) before Claude ever
  starts.
- `-List` shows every project, its target branch, and state (ok / paused / see notes /
  MISSING if the path doesn't exist).
- `all` opens one window per active (non-paused, non-support) project, staggered
  20s apart, with an explicit warning about a prior out-of-memory incident on this
  machine (2026-09-19) telling the user to close windows they're not using.
- `.cmd` is a thin wrapper so it's runnable from `cmd.exe`/Run-dialog/a shortcut without
  changing the system PowerShell execution policy (`-ExecutionPolicy Bypass -File`,
  scoped to this one script invocation only).

**Not yet ported:** nothing prevents starting a session by just opening a terminal in
a folder directly, bypassing all of the above checks. There's no enforcement, only a
documented convention.

## 2. `afx-projects.json` schema (kept machine-local by design, see note below)

One entry per project:
```json
{
  "key": "htr",
  "aliases": ["my-app"],
  "name": "My App",
  "path": "C:\\Users\\you\\Projects\\my-app",
  "repo": "my-org/my-app",
  "defaultBranch": "main",
  "stagingBranch": "staging",
  "paused": false,
  "notes": ""
}
```
Plus a top-level `"neverWorkIn"` array of forbidden paths (temp/scratch folders, stray
old clone locations, `C:\afx`, etc. — see finding below on why this list exists) and a
`"support": true` flag for repos that aren't full ventures (mobile-docs, device-optimizer,
mobile/swift templates, app-preview).

**Deliberately NOT copied into this branch/repo:** the live file itself. It's a
frequently-edited, single-owner-updated source of truth (paths move, projects pause,
notes get added) — putting a copy in git would create a second copy that immediately
starts drifting from the real one. If a portable/parity version is wanted, treat this
schema block as the spec and generate a machine-appropriate equivalent (e.g. a
`~/Projects/afx-projects.json` with Mac paths) rather than syncing the
Windows file's actual content.

## 3. Long paths and line endings

- `git config --global core.longpaths` = `true` (already set on this machine — required
  given how deep this machine's canonical paths get once a worktree + pnpm's own long
  `.pnpm/<pkg>@<version>/...` paths are added on top; see A-XPLAT-9 in the cross-platform
  lessons doc, `docs/lessons-inbox/cross-platform.md` in a product repo).
- `git config --global core.autocrlf` = unset (no explicit global policy). No global
  `core.attributesfile` configured either. Line-ending handling is therefore whatever
  each repo's own `.gitattributes` says, with no machine-wide fallback — worth deciding
  explicitly for the portability effort rather than leaving implicit.
- `virtualStoreDirMaxLength` (pnpm) is set per-repo where needed (a product repo, added
  2026-09-26 after a real `ERR_PACKAGE_IMPORT_NOT_DEFINED` failure traced to Windows
  `MAX_PATH`), not machine-wide.

## 4. No Windows Task Scheduler automation

Checked `schtasks /query /fo LIST /v` for anything AFX/claude-related:
**none found.** Nothing on this machine runs on a schedule outside an active Claude Code
session. Any "daily digest" / "weekly hub sync" cadence described in this repo's own
`STANDING_AGENT_ROSTER_OPERATIONS.md` is manual/session-triggered here, not
cron/Task-Scheduler-driven. Worth knowing before assuming a Linux `cron`-based script
has a Windows equivalent already running — it doesn't.

## 5. One-off audit/sweep output convention (not a maintained tool)

a sync folder under `C:\Users\you\Projects\` — a machine-local (not-in-git) folder
holding raw JSON/markdown output from a past portfolio-wide sweep (`PR_SWEEP.json/.md`,
`doc_inventory.json`, `merged_check.json`, `replit_audit.json`, `rescue_manifest.json`,
`sentinel_report.json`). This is a **pattern**, not a script: ad hoc sweep/audit work
tends to land in a dated top-level folder under `Projects\` rather than in any repo,
which means it's genuinely at risk of being lost if this machine is wiped or the folder
is cleaned up without anyone checking it first. Worth a documented convention (or a
required "land findings as a docs PR" rule) rather than leaving this as the default.

## 6. Finding, not a tool: stale `C:\afx\*` entries in git's global `safe.directory` list

`git config --global --get-all safe.directory` returned dozens of entries under
`C:/afx/...` (scratch sync folders, `lockfix/<repo>` for at
least 9 different repos, and more) — `C:\afx` is explicitly on this machine's own forbidden-path list
(`afx-projects.json`'s `neverWorkIn`, and the global CLAUDE.md) precisely because
past sessions cloned/worked there before that rule existed. **Checked: `C:\afx` no
longer exists on disk** (confirmed via direct `ls`), so this is stale git config
metadata, not an active disk-usage or rule-violation issue today — but it's a real
artifact of the exact problem this machine's rules were written to prevent, and a
useful concrete example if the parity effort wants one. `git config --global
--unset-all safe.directory` (or removing individual stale entries) would clean this up;
not done here since it's config hygiene, not urgent.

## Suggested Windows-side guard equivalents worth building (not yet built)

- A PowerShell `git worktree remove` wrapper implementing the fallback sequence from
  A-XPLAT-1 (plain delete on "Result too large", then retry; hard-stop and report on
  "corrupted and unreadable" rather than continuing).
- A `schtasks`-based (or session-triggered, matching current practice) equivalent of
  whatever cron-driven digest/sweep jobs exist on Mac/Linux, if parity actually requires
  scheduled runs rather than session-triggered ones — current state here is 100%
  session-triggered, zero scheduled automation.
- A repo-agnostic version of `afx-terminal-agent-launcher.ps1`'s pre-flight checks (right repo in the
  right folder, fetch-not-pull, unpushed/uncommitted/stash/worktree summary) as a
  standalone `afx-guard` script rather than baked into one launcher script, so it can be
  reused the way `afx-preflight.sh`/`afx-fragment-audit.sh` are on Mac/Linux.

## Built for parity, 2026-09-27 (this PR)

All of "suggested... not yet built" above is now built, in this folder:

- **`afx-worktree-remove.ps1`** — the A-XPLAT-1 fallback sequence: `git worktree
  remove --force`, then on "Result too large" a `Remove-Item -Recurse -Force`
  followed by a retry, and a hard STOP (not a further retry) on "corrupted and
  unreadable" so real filesystem corruption is escalated rather than masked.
  This one is native PowerShell on purpose — the failure mode is Windows-only.
- **`afx-run.ps1`, `afx-preflight.ps1`, `afx-preserve-all.ps1`** — thin
  wrappers over the portable `../afx-run.sh` / `../afx-preflight.sh` /
  `../afx-preserve-all.sh`, run through Git for Windows' `bash.exe` (already a
  prerequisite on this machine for git itself). **Decision: Git Bash over a
  parallel PowerShell reimplementation**, because:
  1. Git for Windows' bash ships MSYS2's coreutils — GNU `sed`, GNU `stat`,
     `md5sum` — so `../afx-platform.sh`'s "BSD vs GNU" branching already
     covers Windows for free; there is no third tool-surface to port.
  2. A second implementation of the timeout/heartbeat/stall/lock logic in
     PowerShell would drift from the bash one over time — the exact failure
     shape this portfolio already has a name for (A-XPLAT-3, pnpm-version
     drift) applied to scripts instead of lockfiles.
  3. Git Bash is a zero-additional-install dependency here: this machine
     cannot do the git operations `CLAUDE.md` requires without it already.
  - `afx-preflight.ps1` still carries a native PowerShell fallback (heuristic
    load/memory approximation) for the rare case Git Bash truly isn't on
    PATH, so a preflight check is never silently skipped.
  - `afx-preserve-all.ps1` has NO native fallback — its git-plumbing (temp
    index, `commit-tree`, per-worktree walk) is intricate enough that a
    second implementation is a real correctness risk, and it isn't
    time-critical the way a preflight gate is, so "install Git for Windows"
    is an acceptable hard dependency there.
- Git-config hygiene (stale `safe.directory` entries, including the
  `C:\afx\...` pattern found on this machine) is checked both ways: natively
  in `afx-preflight.ps1`'s fallback path, and via `../afx-fragment-audit.sh`
  when run under Git Bash (its `afx_platform_os` branch already recognizes
  Windows/MSYS and applies the same `C:\afx` pattern check).
- `afx-terminal-agent-launcher.sh` (macOS/Linux port of `afx-terminal-agent-launcher.ps1`; `afx-open.sh` is a shim) lives in `../` and
  shares this folder's `afx-projects.example.json` schema — see that
  file for the one-schema-three-machines convention and why the *live*
  `afx-projects.json` is deliberately never committed.
- See `docs/sdlc-playbook/AFX_PLATFORM_PARITY.md` (hub repo) for the full
  parity matrix and the exact validation checklist to run on this machine.
