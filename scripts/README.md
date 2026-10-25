# afx-guard hooks (versioned copies)

The **live** hooks run from `~/.claude/hooks/afx-guard/` (user-level Claude Code config).
These are **version-controlled copies** for recovery, review, and sharing — edits here are
NOT automatically live; sync to `~/.claude/hooks/afx-guard/` to activate.

- `afx-policy-guard.mjs` — SessionStart briefing + PreToolUse guards (worktree discipline,
  no `git reset --hard`/force-push without OK, secret scan) + Stop gate (uncommitted/unpushed).
  The Stop gate counts unpushed commits against the **true remote head** via
  `git ls-remote refs/heads/<branch>` (not the local tracking ref, which goes stale in a
  worktree whose fetch refspec maps only some branches), with an offline fallback.
- `afx-branch-census.sh` — read-only. Classifies every remote branch of every registered repo against its default
  branch (CONTAINED / ALREADY-APPLIED / CLEAN-AHEAD / CONFLICT / STALE-UNMERGED / PRESERVED) and, with
  `--registry-check`, flags registry drift (wrong origin or default branch, duplicate clones, dirty or behind
  canonical clones). Run daily by `afx-sweep.sh` on machines that have `afx-projects.json`; output
  `BRANCH_CENSUS_LATEST.md`. Test: `afx-branch-census.test.sh`. Why it exists: `artifacts/afx-website/docs/AFX_FLEET_COHERENCE.md`.
- `afx-pr-ready.sh` — lists open PRs that are safe to merge by rule (Evidence in the body, clean, mergeable) and merges them
  only with `--execute`, capped per run. Hard stops: a secret or `.env` value in the diff, and destructive SQL without a
  `snapshot: <ref>` line naming an `archive/` or `refs/afx/` ref that exists on origin (checked with `git ls-remote`). Test: `afx-pr-ready.test.sh`.
- `afx-land.sh` — the one way to merge. Run it on your work branch: it merges the current default branch in (a conflict
  stops it and goes to the author), runs your gate (through `afx-gate-run.sh` when present; no gate, no merge), pushes (never
  force), opens the PR with an Evidence section containing the literal gate command and EXIT code, checks the rules with
  `afx-pr-ready.sh --pr N`, merges with a normal merge commit, verifies the tip is in the default branch, and deletes its own
  branch. Only the hard stops above (secret or `.env` value, destructive SQL without a real snapshot ref) need the label `owner-ok`;
  mass deletions, deploy config, package.json, lockfiles, rules files and the registry are normal changes. Test: `afx-land.test.sh`.
- `afx-ratchet.sh` — error ratchet for red baselines: a committed `.afx/ratchet-baseline.json` (tsc error keys, failing test names); fails only on
  NEW errors, prints the burn-down, `--lower` locks it in. `afx-land.sh` runs it only when the repo has that file. Docs: `docs/ops/ERROR_RATCHET.md`.
  Optional GitHub check templates (never the merge gate) are in `github-templates/`; branch-protection plan: `docs/ops/REQUIRED_CHECKS_2026-10-08.md`. Test: `afx-ratchet.test.sh`.
- `afx-sync-clones.sh` — brings registered clones onto a current default branch only when that cannot lose work (clean tree,
  branch fully merged, nothing unpushed); reports everything else. Dry run by default, `--apply` to act. Test: `afx-sync-clones.test.sh`.

- `afx-terminal-agent-launcher.sh` (Windows: `windows/afx-terminal-agent-launcher.ps1`/`.cmd`) - the one way to start a
  terminal-agent session on any machine. Starts in the home folder (`AFX_LAUNCH_DIR` overrides), names the focus project
  to the agent, `--at-project` starts in the clone, `root` has no focus project. `afx-open.sh` and the older launcher names are
  forwarding shims (renamed 2026-10-14). Design: `ops/AFX_MACHINE_BOOTSTRAP.md`.
- `afx-bootstrap.sh` - OS-neutral, private-by-construction setup for a fresh machine (uses the caller's `gh` access; no
  embedded credentials; writes only under `~/.afx`). `--check` is read-only.

- Ship controls (2026-10-23, after TestFlight builds shipped with the old template UX, a preview behind auth, "server did not accept token",
  Metro image-size build failures and a SIMCHECK false OK). All offline-tested (`*.test.sh`), none of them builds, boots or ships anything:
  - `afx-api-health-gate.sh <app> [--json]` - GET-only probes of the app's eas.json production host (DNS/TLS, JSON health route, data routes, JSON 401 on gated
    routes) plus eas.json profile lint (HUB_EXCHANGE parity across profiles, every profile host resolves, `ascAppId` == `APPLE_ID` in `afx-ship-all.sh`).
    Per-venture routes live in `registry/afx-api-health.json`. Exit 0/1, one verdict line per check. Wired into `ops/ship-kit/afx-ship-all.sh`: a real ship refuses on a FAIL;
    `--dry-run` prints the status; the only override is `AFX_API_GATE_WARN_ONLY=1 AFX_API_GATE_OVERRIDE_REASON="<owner words>"` (logged to `~/.afx/ship-overrides.log`).
  - `afx-ux-frames.sh <app>` - UX-preview proof: validates `docs/design/ux-preview-frames.json` (`--validate-manifest`, no simulator), or generates one Maestro flow per item and runs it against an
    already installed Release app on a booted simulator, writing frames + `result.json` to `~/.afx/evidence/<app>-<date>/` (proof PASS/FAIL, Couldn't-load/blank/black/springboard flags).
    Optional `--mockup-renders DIR` adds side-by-side + parity score (`afx-ux-parity.py`). `afx-ship-approve.sh` requires a clean result for the same origin/main sha for apps that have a manifest.
  - `afx-metro-canary.sh <app-dir>` - when the lockfile resolves image-size 2.x, calls Metro's `getAssetData` on a real png (seconds) and reports the known failure signature;
    run by `afx-ship-all.sh` after the install and before the prebuild.
  - `afx-venture-health-sweep.sh [--write]` - runs the gate for every venture and writes the `~/.afx/agents/VENTURE_HEALTH.md` table (dry run by default; no launchd job installed).
  - `afx-sim-check.sh` / `afx-frame-compare.py`: exit 33 when the final simulator frame is the iOS home screen (SpringBoard); the alive check is scoped to the check's own device.
