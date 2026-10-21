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
  canonical clones). Run daily by `afx-sweep.sh` on machines that have `allforx-projects.json`; output
  `BRANCH_CENSUS_LATEST.md`. Test: `afx-branch-census.test.sh`. Why it exists: `artifacts/afx-website/docs/AFX_FLEET_COHERENCE.md`.
- `afx-pr-ready.sh` — lists open PRs that are safe to merge by rule (Evidence in the body, clean, no protected paths,
  no mass deletion) and merges them only with `--execute`, capped per run. Dependency, migration, deploy and rules
  changes are never READY. Test: `afx-pr-ready.test.sh`.
- `afx-land.sh` — the one way to merge. Run it on your work branch: it merges the current default branch in (a conflict
  stops it and goes to the author), runs your gate (through `afx-gate-run.sh` when present; no gate, no merge), pushes (never
  force), opens the PR with an Evidence section containing the literal gate command and EXIT code, checks the rules with
  `afx-pr-ready.sh --pr N`, merges with a normal merge commit, verifies the tip is in the default branch, and deletes its own
  branch. Protected changes (deploy/replit config, migrations, package.json and lockfiles, rules files, the registry, mass
  deletions) need the label `owner-ok` on the PR. Test: `afx-land.test.sh`.
- `afx-ratchet.sh` — error ratchet for red baselines: a committed `.afx/ratchet-baseline.json` (tsc error keys, failing test names); fails only on
  NEW errors, prints the burn-down, `--lower` locks it in. `afx-land.sh` runs it only when the repo has that file. Docs: `docs/ops/ERROR_RATCHET.md`.
  Optional GitHub check templates (never the merge gate) are in `github-templates/`; branch-protection plan: `docs/ops/REQUIRED_CHECKS_2026-10-08.md`. Test: `afx-ratchet.test.sh`.
- `afx-sync-clones.sh` — brings registered clones onto a current default branch only when that cannot lose work (clean tree,
  branch fully merged, nothing unpushed); reports everything else. Dry run by default, `--apply` to act. Test: `afx-sync-clones.test.sh`.

- `afx-terminal-agent-launcher.sh` (Windows: `windows/afx-terminal-agent-launcher.ps1`/`.cmd`) - the one way to start a
  terminal-agent session on any machine. Starts in the home folder (`AFX_LAUNCH_DIR` overrides), names the focus project
  to the agent, `--at-project` starts in the clone, `root` has no focus project. `afx-open.sh` and `Open-AllForX.*` are
  forwarding shims (renamed 2026-10-14). Design: `ops/AFX_MACHINE_BOOTSTRAP.md`.
- `afx-bootstrap.sh` - OS-neutral, private-by-construction setup for a fresh machine (uses the caller's `gh` access; no
  embedded credentials; writes only under `~/.afx`). `--check` is read-only.
