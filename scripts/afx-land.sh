#!/bin/bash
# afx-land.sh: land the current branch on the default branch, safely, from any machine or agent. THE one way to merge.
# Owner decision 2026-10-08: every machine/agent may merge its own code. This script is what makes that safe: it does
# the steps people and agents skip (fresh base, gate, evidence, rules, cleanup), so merging never creates divergence.
#
#   scripts/afx-guard/afx-land.sh --gate "<command>" [--title T] [--body-file F] [--slug owner/repo] [--base main] [--dry-run] [--keep-branch]
#   scripts/afx-guard/afx-land.sh [--no-ratchet] ...           skip the optional error ratchet (see step 3b)
#   scripts/afx-guard/afx-land.sh --shots ...                  OPT-IN advisory (step 9): after a landing, if the repo has shots.config.json and the
#                                                              merged diff touches app source, print the exact afx-shots command (docs/AFX_SHOTS.md)
#   scripts/afx-guard/afx-land.sh --gate-docs-only  [...]     (only when every changed file is a .md or under docs/)
#   scripts/afx-guard/afx-land.sh --cleanup [--discard-churn] [--base main] [--no-janitor] [--janitor-hours N]
#                                                              remove THIS worktree and its local branch, but only after confirming
#                                                              the tip is in origin/<base> or equals the pushed remote branch (exit 7 otherwise).
#                                                              Then runs afx-worktree-clean.sh over the repo (merged + clean + idle >= N hours,
#                                                              default 24; skip with --no-janitor). If the folder cannot be deleted ("Directory not
#                                                              empty", "Permission denied") the exact one-line manual command is printed and the exit is 8.
#
# Steps, in order; it stops at the first failure and says why (exit codes below):
#   1 preflight   inside a git repo, on a work branch (never the default branch), no modified tracked files, fetch origin
#   2 fresh base  if origin/<base> is not already in this branch, merge it in; a merge CONFLICT is not resolved by the tool:
#                 the merge is aborted and the author fixes it (exit 3)
#   3 gate        --gate runs through afx-gate-run.sh (the 3-slot lock) when present; its exit code must be 0 (exit 4).
#                 No gate, no merge: --gate-docs-only is the only exception and it checks the files really are docs.
#   3b ratchet    OPTIONAL: only when the target repo has .afx/ratchet-baseline.json. afx-ratchet.sh run --lower re-runs the stored
#                 typecheck/test commands and fails (exit 4) on any NEW tsc error or newly failing test; a lower count is committed
#                 into the branch as the new baseline. Repos without that file are untouched. Docs-only landings skip it.
#   4 push        plain push of this branch, never a force (exit 6 if it is rejected)
#   5 pull request  created or reused; an Evidence section with the literal gate command and EXIT code is written into its body
#   6 rules       afx-pr-ready.sh --pr N must say READY: clean, Evidence with a literal EXIT 0, and none of the hard stops (secret or .env value,
#                 destructive SQL, mass deletion of more than 200 tracked files, deploy/workflow config) unless the owner put the label `owner-ok` (exit 5)
#   7 merge       `gh pr merge --merge` (a normal merge commit), then verify the branch tip really is in origin/<base> (exit 6)
#   8 cleanup     delete THIS branch on the remote (never rescue/ preserve/ archive/ backup/ salvage/ prefixes); report
# --fixes-main (2026-10-13): when afx-main-health.sh recorded that this repo's current main fails its full gate, afx-land.sh stops
#   (exit 5) unless the change is marked as that fix with --fixes-main (stated in the PR Evidence). Main stays green. A repo with an
#   error-ratchet baseline is in a burn-down: its ratchet already blocks any new error, so the red-main block does not apply there.
# --cleanup extras (2026-10-13): works on a detached HEAD whose commit is in origin/<base>; never deletes a local branch with a protected
#   prefix; copies gitignored env/key files to ~/.afx/set-aside/<date>/<repo>/<worktree>/secrets before removing the folder.
#   --cleanup --discard-churn also clears small generated edits: the tracked diff is saved as tracked-edits.patch and untracked files are
#   moved (not deleted) into the same set-aside folder. It refuses migrations/SQL/env edits and anything over 25 files or 600 lines
#   (AFX_CHURN_MAX_FILES / AFX_CHURN_MAX_LINES), so real work is committed and pushed, never discarded.
# After ANY stop (exit 3 to 6) the commits may exist only in this worktree: never remove it or delete the branch by hand
# (on 2026-10-08 a cleanup line run after a failed gate deleted the only copy of a commit). Use --cleanup, which checks first.
#   9 shots       OPT-IN, advisory, never changes the exit code: with --shots, when <repo>/shots.config.json exists and the merged diff touches
#                 files outside docs, print `afx-shots run <venture> --changed-since <pre-merge sha> --diff` (docs/AFX_SHOTS.md "Maintenance loop")
#   7b verify     (2026-10-15) after the merge, afx-main-health.sh --only <repo> runs the repo's gate row against the merged main in the
#                 background; RED writes ~/.afx/alerts/<repo>-<sha>.txt, notifies and shows in the afx-where-am-i banner.
#   4b main row   (2026-10-15) the repo's main-gates.txt row is the MINIMUM gate: when --gate does not contain it, the row runs too (Replit via
#                 afx-remote-gate.sh for a hosted repo, local otherwise) after the push; the PR Evidence names both. Gate text always runs
#                 under `bash -o pipefail -c`; an empty or no-op gate (true, :, exit 0, echo ...) is refused unless --gate-docs-only.
#   6b lock       (2026-10-15) a per-repo landing lock (afx-lock.sh, ~/.afx/locks/land-<repo>.lock) is held across the merge; if origin/<base>
#                 moved meanwhile it is merged in and the whole flow re-runs under the lock (max 3 passes), so concurrent landings are
#                 each gated against the main they will land on. Released on exit; a dead holder is reclaimed.
# Exit codes: 0 landed (or dry-run passed), 2 usage/preflight, 3 conflict, 4 gate failed or missing, 5 rules say not ready, 6 push/merge failed,
#             7 --cleanup refused (the tip is not on GitHub), 8 --cleanup done on GitHub's side but the worktree folder could not be deleted
#             (the manual command is printed; nothing is lost).
# Portable to bash 3.2 / Git Bash. `gh` is overridable with AFX_GH for tests.
set -u
SELF="${BASH_SOURCE[0]:-$0}"; case "$SELF" in /*) ;; *) SELF="$PWD/$SELF";; esac
ORIG_ARGS=("$@")   # kept for step 6b, which re-runs this script when origin moved while it waited for the landing lock
_AFX_LAND_DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
. "$_AFX_LAND_DIR/afx-platform.sh"
GH="${AFX_GH:-gh}"
GATE=""; DOCS_ONLY=0; TITLE=""; BODY_FILE=""; SLUG="${AFX_LAND_SLUG:-}"; BASE=""; DRY=0; KEEP=0; CLEANUP=0; DISCARD=0; FIXES_MAIN=0; NO_RATCHET=0; SHOTS=0; JANITOR=1; JANITOR_H=24
while [ $# -gt 0 ]; do
  case "$1" in
    --gate) GATE="$2"; shift 2;;
    --gate-docs-only) DOCS_ONLY=1; shift;;
    --title) TITLE="$2"; shift 2;;
    --body-file) BODY_FILE="$2"; shift 2;;
    --slug) SLUG="$2"; shift 2;;
    --base) BASE="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    --keep-branch) KEEP=1; shift;;
    --cleanup) CLEANUP=1; shift;;
    --discard-churn) DISCARD=1; shift;;
    --fixes-main) FIXES_MAIN=1; shift;;
    --no-ratchet) NO_RATCHET=1; shift;;
    --shots) SHOTS=1; shift;;
    --no-janitor) JANITOR=0; shift;;
    --janitor-hours) JANITOR_H="$2"; shift 2;;
    -h|--help) sed -n '2,/^# Portable/p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "afx-land: unknown argument $1" >&2; exit 2;;
  esac
done
die() { code="$1"; shift; echo "afx-land: STOP ($code): $*" >&2
  case "$code" in 3|4|5|6) echo "afx-land: KEEP this worktree and branch: the commits may exist only here. Fix and re-run; remove them only with 'afx-land.sh --cleanup', which checks they are on GitHub first." >&2;; esac
  exit "$code"; }
say() { echo "afx-land: $*"; }

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die 2 "not inside a git repository"
cd "$ROOT" || die 2 "cannot enter $ROOT"
BRANCH=$(git branch --show-current 2>/dev/null); [ -z "$BRANCH" ] && [ "$CLEANUP" != 1 ] && die 2 "detached HEAD: switch to a work branch first"
[ "$DISCARD" = 1 ] && [ "$CLEANUP" != 1 ] && { echo "afx-land: --discard-churn only works with --cleanup" >&2; exit 2; }
if [ -z "$BASE" ]; then
  BASE=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  # origin/HEAD can point at a branch that no longer exists (seen: origin/Claude-Code); fall back to main, then master
  if [ -z "$BASE" ] || ! git rev-parse --verify -q "refs/remotes/origin/$BASE" >/dev/null; then
    for cand in main master; do git rev-parse --verify -q "refs/remotes/origin/$cand" >/dev/null && { BASE="$cand"; break; }; done
  fi
  [ -z "$BASE" ] && BASE=main
fi
case "$JANITOR_H" in ''|*[!0-9]*) echo "afx-land: --janitor-hours needs a whole number" >&2; exit 2;; esac
case "$BRANCH" in "$BASE"|main|master|staging) die 2 "refusing to land from '$BRANCH': work on a wip/<topic> branch";; esac

# --cleanup: remove this worktree and its local branch, only when nothing can be lost.
if [ "$CLEANUP" = 1 ]; then
  afx_platform_timeout 120 git fetch -q origin || die 7 "--cleanup refused: could not fetch origin, so the tip cannot be confirmed"
  TIP=$(git rev-parse HEAD)
  WHERE=""
  if git merge-base --is-ancestor "$TIP" "origin/$BASE" 2>/dev/null; then WHERE="in origin/$BASE"
  elif [ -n "$BRANCH" ] && [ "$(git ls-remote origin "refs/heads/$BRANCH" 2>/dev/null | cut -f1)" = "$TIP" ]; then WHERE="pushed as origin/$BRANCH (not merged yet)"
  fi
  # A detached HEAD has no branch to push, so it can be cleaned up only when its commit is already in the base branch.
  [ -z "$WHERE" ] && [ -z "$BRANCH" ] && die 7 "--cleanup refused: detached HEAD $TIP is not in origin/$BASE. It exists only here; put it on a branch and push or land it first."
  [ -z "$WHERE" ] && die 7 "--cleanup refused: $TIP on $BRANCH is neither in origin/$BASE nor pushed to origin/$BRANCH. It exists only here; push or land it first."
  # --discard-churn (owner decision 2026-10-13: "discard churn edits once the patch is saved"). The sanctioned way to clear a leftover
  # worktree whose commits are safe on GitHub but which still holds small generated edits (a build-number bump, a regenerated sitemap or
  # manifest, a lockfile tweak). Nothing is deleted: the tracked diff is saved as a patch and untracked files are MOVED, both into the
  # set-aside folder. It refuses anything that looks like real work, so judging "is this churn" is not left to the caller alone.
  if [ "$DISCARD" = 1 ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    SA=$(afx_platform_set_aside_dest "$ROOT"); MAXF="${AFX_CHURN_MAX_FILES:-25}"; MAXL="${AFX_CHURN_MAX_LINES:-600}"
    CH_FILES=$(git diff --name-only HEAD 2>/dev/null)
    RISKY=$(printf '%s\n' "$CH_FILES" | grep -E '(^|/)migrations?/|\.sql$|(^|/)\.env(\.|$)' | head -3 | tr '\n' ' ')
    [ -n "$RISKY" ] && die 7 "--discard-churn refused: the edits touch a migration, SQL or env file ($RISKY). That is never churn: commit and push it, or ask the owner."
    UNTR=$(git ls-files --others --exclude-standard --directory 2>/dev/null)
    UNTR_REAL=$(printf '%s\n' "$UNTR" | grep -vE '(^|/)(node_modules|build|dist|ios|android|static-build|shots|__pycache__|\.gate-logs|\.expo|\.husky|\.turbo|\.next|coverage)/$' | grep -vE '(^|/)\.(agents|cursor|github|claude)/skills/' | grep -c .)
    NF=$(printf '%s\n' "$CH_FILES" | grep -c .); NL=$(git diff --numstat HEAD 2>/dev/null | awk '{a+=$1+$2} END{print a+0}')
    if [ "$((NF+UNTR_REAL))" -gt "$MAXF" ] || [ "$NL" -gt "$MAXL" ]; then
      die 7 "--discard-churn refused: $NF edited file(s), $UNTR_REAL new file(s), $NL changed line(s) is more than churn (limits: $MAXF files, $MAXL lines). Commit and push it on a branch instead."
    fi
    mkdir -p "$SA" || die 7 "--discard-churn refused: cannot create $SA"
    if [ "$NF" -gt 0 ]; then
      git diff --binary HEAD > "$SA/tracked-edits.patch" 2>/dev/null; [ -s "$SA/tracked-edits.patch" ] || die 7 "--discard-churn refused: could not save the patch to $SA/tracked-edits.patch"
    fi
    printf '%s\n' "$UNTR" | while IFS= read -r u; do
      [ -n "$u" ] || continue; u="${u%/}"
      mkdir -p "$SA/untracked/$(dirname "$u")" && mv "$ROOT/$u" "$SA/untracked/$u" || exit 1
    done || die 7 "--discard-churn stopped: an untracked file could not be moved to $SA/untracked (nothing was discarded)"
    [ "$NF" -gt 0 ] && { git restore --staged --worktree -- :/ 2>/dev/null || die 7 "--discard-churn stopped: git restore failed (the patch is in $SA)"; }
    say "discard-churn: saved $NF edited file(s) as $SA/tracked-edits.patch and moved $(printf '%s\n' "$UNTR" | grep -c .) untracked item(s) to $SA/untracked"
  fi
  [ -n "$(git status --porcelain 2>/dev/null)" ] && die 7 "--cleanup refused: this worktree has uncommitted or untracked files (generated churn only? re-run with --cleanup --discard-churn, which saves a patch first)"
  COMMON=$(cd "$(git rev-parse --git-common-dir)" && pwd); GITDIR=$(cd "$(git rev-parse --git-dir)" && pwd)
  if [ "$COMMON" = "$GITDIR" ]; then
    say "cleanup: $TIP is $WHERE. This is the main checkout, not a worktree: nothing removed. Switch it to $BASE with afx-sync-clones.sh."
    exit 0
  fi
  MAIN_WT=$(dirname "$COMMON")
  cd "$MAIN_WT" || die 7 "--cleanup refused: cannot enter the main checkout $MAIN_WT"
  # gitignored env/key files do not show in `git status` and would be deleted with the folder: keep a copy first.
  SA_MSG=$(afx_platform_set_aside_secrets "$ROOT") || die 7 "--cleanup refused: an env/key file in this worktree could not be copied to the set-aside folder"
  [ -n "$SA_MSG" ] && say "cleanup: $SA_MSG"
  RM_ERR=$(git worktree remove "$ROOT" 2>&1) && RM_OK=1 || RM_OK=0
  # git can fail half way ("failed to delete ...: Directory not empty", "Permission denied" on Windows when an editor or antivirus holds a file).
  # Judge by the disk, not by the exit code: if the folder is gone the cleanup is done.
  if [ ! -d "$ROOT" ]; then REMOVED=yes; else REMOVED=no; fi
  # -D is safe here: the tip was just confirmed on GitHub, and -d would refuse a merge-commit merge the local main has not fetched.
  # If git still has the worktree registered with this branch checked out, git refuses and the branch is simply kept.
  git worktree prune >/dev/null 2>&1
  # rescue/ preserve/ archive/ backup/ salvage/ recovered-* are permanent history: only the owner deletes them, local or remote.
  case "$BRANCH" in
    "") BR_GONE="n/a (detached HEAD)";;
    rescue/*|preserve/*|archive/*|backup/*|salvage/*|recovered-*) BR_GONE="no (protected prefix: kept)";;
    *) git branch -D "$BRANCH" >/dev/null 2>&1 && BR_GONE=yes || BR_GONE=no;;
  esac
  say "cleanup: $TIP is $WHERE. worktree-removed=$REMOVED local-branch-deleted=$BR_GONE"
  if [ "$REMOVED" = yes ] && [ "$JANITOR" = 1 ] && [ -x "$_AFX_LAND_DIR/afx-worktree-clean.sh" ]; then
    say "janitor: afx-worktree-clean.sh over $MAIN_WT (merged + clean + idle >= ${JANITOR_H}h only; --no-janitor skips this)"
    afx_platform_timeout 300 bash "$_AFX_LAND_DIR/afx-worktree-clean.sh" "$MAIN_WT" --base "$BASE" --min-age-hours "$JANITOR_H" 2>&1 | sed 's/^/    | /'
  fi
  if [ "$REMOVED" = no ]; then
    echo "afx-land: ORPHAN FOLDER left behind (nothing is lost: the tip is $WHERE). git said: $(printf '%s' "$RM_ERR" | tr '\n' ' ' | cut -c1-300)" >&2
    echo "afx-land: close any editor/terminal/antivirus using $ROOT, retry '$0 --cleanup' from the main checkout, or run this ONE line (moves it to the Trash, then prunes git's records):" >&2
    # The script directory may be INSIDE the worktree that failed to delete (this very script was run from it): point the one-liner at
    # the main checkout's copy, else the installed copy, never at a path that no longer resolves.
    _G="$_AFX_LAND_DIR"
    [ -f "$_G/windows/afx-worktree-remove.ps1" ] && case "$_G" in "$ROOT"/*) _G="";; esac || _G=""
    [ -z "$_G" ] && [ -f "$MAIN_WT/scripts/afx-guard/windows/afx-worktree-remove.ps1" ] && _G="$MAIN_WT/scripts/afx-guard"
    [ -z "$_G" ] && [ -f "$HOME/.afx/afx-guard/windows/afx-worktree-remove.ps1" ] && _G="$HOME/.afx/afx-guard"
    echo "    $(AFX_GUARD_DIR="${_G:-$_AFX_LAND_DIR}" afx_platform_trash_cmd "$ROOT" "$MAIN_WT")" >&2
    echo "afx-land: list every leftover folder across all repos (read-only): bash $_AFX_LAND_DIR/afx-worktree-clean.sh --orphans <clones-root>" >&2
    exit 8
  fi
  exit 0
fi
if [ -z "$SLUG" ]; then
  SLUG=$(git remote get-url origin 2>/dev/null | sed -e 's#^git@github.com:#github.com/#' -e 's#^https\{0,1\}://##' -e 's#^[^/]*@##' -e 's#^github.com/##' -e 's#\.git$##')
fi
[ -z "$SLUG" ] && die 2 "cannot tell owner/repo from origin; pass --slug owner/repo"
[ -n "$(git status --porcelain -uno 2>/dev/null)" ] && die 2 "modified tracked files: commit or stash them first (nothing is discarded for you)"
[ -z "$GATE" ] && [ "$DOCS_ONLY" = 0 ] && die 4 "no gate given: pass --gate \"<command>\" (or --gate-docs-only for docs). No gate, no merge."
# A gate that proves nothing is refused (2026-10-15: gates ended in a pipe or were `true`). Every `&&`/`;`/`||` segment of the gate text
# must be a real command: an empty, `true`, `:`, `exit 0`, `echo ...` or `printf ...` segment alone never counts. --gate-docs-only is the
# one sanctioned way to land docs without a code gate.
if [ "$DOCS_ONLY" = 0 ]; then
  REAL_SEG=0
  while IFS= read -r seg; do
    seg=$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$seg" in ''|true|:|'exit 0'|echo|echo\ *|printf\ *) ;; *) REAL_SEG=1;; esac
  done <<GATESEG
$(printf '%s\n' "$GATE" | awk '{gsub(/&&|\|\||;/,"\n"); print}')
GATESEG
  [ "$REAL_SEG" = 0 ] && die 4 "the gate is empty or a no-op ($GATE): it proves nothing. Pass the real gate (the repo's main-gates.txt row is the minimum), or --gate-docs-only for a docs-only change. No gate, no merge."
fi

say "fetching origin"
afx_platform_timeout 180 git fetch -q origin || die 2 "git fetch failed"
git rev-parse --verify -q "origin/$BASE" >/dev/null || die 2 "origin/$BASE not found"

# 2 fresh base
MERGED_BASE=0
if ! git merge-base --is-ancestor "origin/$BASE" HEAD; then
  say "origin/$BASE moved: merging it into $BRANCH"
  if ! git merge --no-edit -q "origin/$BASE" >/dev/null 2>&1; then
    git merge --abort >/dev/null 2>&1
    die 3 "merge conflict with origin/$BASE. The merge was aborted and nothing was changed. The author resolves it, then re-run."
  fi
  MERGED_BASE=1
fi
# 2b agent-rules drift (owner 2026-10-19): the AFX rules block must match the hub template in this repo's AGENTS.md, replit.md,
# Cursor, Copilot and CONVENTIONS.md files, as merged with origin/$BASE. AFX_LAND_NO_RULES_CHECK=1 is for the throwaway repos in tests only. Fix: afx-agent-rules-sync.sh --write <repo>, commit, land.
if [ -z "${AFX_LAND_NO_RULES_CHECK:-}" ] && [ -x "$_AFX_LAND_DIR/afx-agent-rules-sync.sh" ]; then
  RULES_OUT=$(bash "$_AFX_LAND_DIR/afx-agent-rules-sync.sh" --check "$ROOT" 2>&1); RULES_RC=$?
  if [ "$RULES_RC" -ne 0 ]; then
    printf '%s\n' "$RULES_OUT" | head -8 >&2
    die 5 "the AFX agent-rules block in this repo has drifted from the hub template (sync --check EXIT $RULES_RC). Run 'bash $_AFX_LAND_DIR/afx-agent-rules-sync.sh --write $ROOT', commit those files with explicit paths, then re-run. If the hub clone is stale, update it first."
  fi
  say "agent-rules block in sync (sync --check EXIT 0)"
fi
BASE_SHA=$(git rev-parse "origin/$BASE")
CHANGED=$(git diff --name-only "origin/$BASE...HEAD")
[ -z "$CHANGED" ] && die 2 "no changes relative to origin/$BASE: nothing to land"

# 3 gate
GATE_LOG="$(mktemp)"; trap 'rm -f "$GATE_LOG" "$GATE_LOG.body"; type afx_lock_release >/dev/null 2>&1 && afx_lock_release' EXIT
if [ "$DOCS_ONLY" = 1 ]; then
  echo "$CHANGED" | grep -Evq '(\.mdc?$|^docs/|/docs/)' && die 4 "--gate-docs-only but non-doc files changed: $(echo "$CHANGED" | grep -Ev '(\.mdc?$|^docs/|/docs/)' | head -3 | tr '\n' ' ')"
  GATE_DESC="docs-only change (no code gate): git diff --check"
  git diff --check "origin/$BASE...HEAD" > "$GATE_LOG" 2>&1; GRC=$?
else
  GATE_DESC="$GATE"
  if [ -x "$_AFX_LAND_DIR/afx-gate-run.sh" ]; then
    say "running the gate through afx-gate-run.sh (slot-locked)"
    AFX_GATE_VERBOSE=1 "$_AFX_LAND_DIR/afx-gate-run.sh" "$ROOT" "land-$BRANCH" -- bash -o pipefail -c "$GATE" > "$GATE_LOG" 2>&1; GRC=$?
  else
    say "running the gate (afx-gate-run.sh not found next to this script)"
    bash -o pipefail -c "$GATE" > "$GATE_LOG" 2>&1; GRC=$?
  fi
fi
# 255 (ssh/remote transport) and 97 (afx-remote-gate: no GATE_EXIT marker) are INFRASTRUCTURE failures, not test results: say so and
# retry once before STOP (2026-10-15: long Replit rows came back 255 although the same gate passed when run directly).
if [ "$DOCS_ONLY" = 0 ] && { [ "$GRC" -eq 255 ] || [ "$GRC" -eq 97 ]; }; then
  say "gate exit $GRC = infrastructure (ssh/remote transport), not a test failure: retrying once"
  if [ -x "$_AFX_LAND_DIR/afx-gate-run.sh" ]; then
    AFX_GATE_VERBOSE=1 "$_AFX_LAND_DIR/afx-gate-run.sh" "$ROOT" "land-$BRANCH" -- bash -o pipefail -c "$GATE" > "$GATE_LOG" 2>&1; GRC=$?
  else bash -o pipefail -c "$GATE" > "$GATE_LOG" 2>&1; GRC=$?; fi
  GATE_DESC="$GATE (first attempt exit 255/97 = infrastructure, retried once)"
fi
tail -n 12 "$GATE_LOG" | sed 's/^/    | /'
if [ "$GRC" -ne 0 ]; then
  if [ "$GRC" -eq 255 ] || [ "$GRC" -eq 97 ]; then die 4 "gate exited $GRC twice: that is infrastructure (ssh/remote transport lost), not a test failure. Re-run the landing; check the repl with afx-remote-ops.sh <VENTURE> status. Nothing was pushed or merged."; fi
  die 4 "gate exited $GRC. Nothing was pushed or merged."
fi
say "gate EXIT: 0"

# 3b optional error ratchet: only when the repo carries a baseline file (repos without one are unaffected)
RATCHET_FILE="$ROOT/.afx/ratchet-baseline.json"; RATCHET_EV=""
[ "$NO_RATCHET" = 1 ] && [ -f "$RATCHET_FILE" ] && RATCHET_EV="SKIPPED by --no-ratchet (visible to reviewers)"
# The ratchet re-runs the repo's typecheck and tests, which needs node_modules. A change made ONLY of guard tooling
# (scripts/afx-guard/**) and docs is covered by the guard's own test suites in --gate and cannot move the app's numbers, so the
# ratchet is skipped for exactly that case and the PR says so. Any other file, of any type, keeps the ratchet.
if [ "$NO_RATCHET" = 0 ] && [ -f "$RATCHET_FILE" ]; then
  RATCHET_ALL=$(git diff --name-only "origin/$BASE...HEAD" 2>/dev/null | grep -c .)
  RATCHET_HITS=$(git diff --name-only "origin/$BASE...HEAD" 2>/dev/null | grep -vcE '^scripts/afx-guard/|^docs/|\.mdc?$')
  if [ "${RATCHET_ALL:-0}" -gt 0 ] && [ "${RATCHET_HITS:-1}" = 0 ]; then NO_RATCHET=1; RATCHET_EV="SKIPPED automatically: every changed file is guard tooling (scripts/afx-guard), docs or rendered rules files (.md/.mdc)"; say "ratchet skipped: only guard tooling and docs changed"; fi
fi
if [ "$DOCS_ONLY" = 0 ] && [ "$NO_RATCHET" = 0 ] && [ -f "$RATCHET_FILE" ] && [ -x "$_AFX_LAND_DIR/afx-ratchet.sh" ]; then
  say "ratchet baseline found: checking for regressions"
  RL=""; [ "$DRY" = 0 ] && RL="--lower"
  # The ratchet runs the repo's own tsc and test runner, so a fresh worktree without node_modules made it crash
  # ("tsc: command not found", exit 4/127) four times on 2026-10-15. Install first, frozen, with the repo's own lockfile.
  if [ ! -d "$ROOT/node_modules" ]; then
    INST=""
    if [ -f "$ROOT/pnpm-lock.yaml" ]; then INST="env CI=true pnpm install --frozen-lockfile --silent"
    elif [ -f "$ROOT/package-lock.json" ]; then
      INST="npm ci --silent --no-audit --no-fund"
      # Lockfiles written on Replit resolve every package through its private mirror
      # (http://package-firewall.replit.local/npm/<pkg>), which does not resolve off Replit. Install from a temporary
      # copy that points at the public registry; the tracked lockfile is restored right after (same packages, same
      # versions, same integrity hashes).
      if grep -q 'package-firewall\.replit\.local/npm/' "$ROOT/package-lock.json"; then
        INST="cp package-lock.json .package-lock.afx-orig && sed -i.bak 's#http://package-firewall.replit.local/npm/#https://registry.npmjs.org/#g' package-lock.json && rm -f package-lock.json.bak; npm ci --silent --no-audit --no-fund; r=\$?; mv -f .package-lock.afx-orig package-lock.json; exit \$r"
      fi
    fi
    if [ -n "$INST" ]; then
      say "no node_modules in this worktree: installing before the ratchet ($INST)"
      if [ -x "$_AFX_LAND_DIR/afx-gate-run.sh" ]; then
        "$_AFX_LAND_DIR/afx-gate-run.sh" "$ROOT" "install-$BRANCH" -- bash -c "cd '$ROOT' && nice -n 10 $INST" > "$GATE_LOG.install" 2>&1; IRC=$?
      else
        (cd "$ROOT" && nice -n 10 bash -c "$INST") > "$GATE_LOG.install" 2>&1; IRC=$?
      fi
      [ "$IRC" -ne 0 ] && { tail -n 8 "$GATE_LOG.install" | sed 's/^/    | /'; rm -f "$GATE_LOG.install"; die 4 "install before the ratchet failed (exit $IRC). Nothing was pushed or merged."; }
      rm -f "$GATE_LOG.install"
    fi
  fi
  # the ratchet re-runs a failing command on origin/<base> in the same environment: what fails there too is pre-existing, not new
  export AFX_RATCHET_BASE_REF="${AFX_RATCHET_BASE_REF:-origin/$BASE}"
  if [ -x "$_AFX_LAND_DIR/afx-gate-run.sh" ]; then
    AFX_GATE_VERBOSE=1 "$_AFX_LAND_DIR/afx-gate-run.sh" "$ROOT" "ratchet-$BRANCH" -- "$_AFX_LAND_DIR/afx-ratchet.sh" run --baseline "$RATCHET_FILE" $RL > "$GATE_LOG.ratchet" 2>&1; KRC=$?
  else
    "$_AFX_LAND_DIR/afx-ratchet.sh" run --baseline "$RATCHET_FILE" $RL > "$GATE_LOG.ratchet" 2>&1; KRC=$?
  fi
  tail -n 14 "$GATE_LOG.ratchet" | sed 's/^/    | /'
  [ "$KRC" -ne 0 ] && { rm -f "$GATE_LOG.ratchet"; { [ "$KRC" -eq 6 ] && die 4 "error ratchet could not install a scope's dependencies (exit 6; see RATCHET: INSTALL FAILED above): an environment problem, not a regression. Nothing was pushed or merged."; die 4 "error ratchet exited $KRC: a new typecheck error or failing test (or a crashed command). Nothing was pushed or merged."; }; }
  RATCHET_EV=$(grep -E '^(tsc|tests) |^RATCHET' "$GATE_LOG.ratchet" | head -8)
  if [ "$DRY" = 0 ] && [ -n "$(git status --porcelain -- .afx/ratchet-baseline.json 2>/dev/null)" ]; then
    git add .afx/ratchet-baseline.json && git commit -q -m "ratchet: lower the error baseline (burn-down locked in by afx-land.sh)" && say "ratchet baseline lowered and committed"
  fi
  rm -f "$GATE_LOG.ratchet"
fi

# 3c main stays green (owner rule 2026-10-13): when afx-main-health.sh recorded that THIS repo's current main fails its full gate,
# only the fix may land. Mark it with --fixes-main; the PR Evidence says so. A record for an older main commit does not block.
# Exception: a repo with an error-ratchet baseline (.afx/ratchet-baseline.json) is in a burn-down. Its ratchet (step 3b) already
# refuses any change that adds an error or a failing test, so ordinary work may continue while main is red, and main only improves.
if [ "$FIXES_MAIN" = 0 ] && [ ! -f "$ROOT/.afx/ratchet-baseline.json" ] && [ -x "$_AFX_LAND_DIR/afx-main-health.sh" ] && [ -n "$SLUG" ]; then
  MAIN_SHA=$(git rev-parse "origin/$BASE" 2>/dev/null)
  if [ -n "$MAIN_SHA" ] && "$_AFX_LAND_DIR/afx-main-health.sh" --is-red "${SLUG##*/}" "$MAIN_SHA" >/dev/null 2>&1; then
    die 5 "main of ${SLUG##*/} fails its full gate (afx-main-health.sh --status). Owner rule: main stays green, so only the fix lands now. If this branch IS that fix, re-run with --fixes-main; otherwise land the fix first. Nothing was pushed or merged."
  fi
fi

# 4 push
HEAD_SHA=$(git rev-parse HEAD)
if [ "$DRY" = 1 ]; then say "dry run: would push $BRANCH ($HEAD_SHA), open/update the PR, check the rules and merge."; fi
if [ "$DRY" = 0 ]; then
  git push -q -u origin HEAD 2>/dev/null || die 6 "push rejected (someone pushed this branch first?). Not forcing."
fi

# 4b the repo's main-gates.txt row is the MINIMUM gate (2026-10-15: a PR passed typecheck only while main-health also runs the
# api-server tests, and main went red). When --gate does not contain the row command, run the row command too: on the venture's Replit
# workspace through afx-remote-gate.sh (it tests the pushed branch, hence after the push), or locally for a repo without a host.
MAIN_ROW_EV=""
if [ "$DOCS_ONLY" = 0 ] && [ -z "${AFX_LAND_NO_MAIN_ROW:-}" ]; then
  MG_FILE="${AFX_MAIN_GATES:-$_AFX_LAND_DIR/main-gates.txt}"
  MG_ROW=$([ -f "$MG_FILE" ] && awk -F'|' -v r="${SLUG##*/}" '$1==r{print; exit}' "$MG_FILE")
  if [ -n "$MG_ROW" ]; then
    MG_VENTURE=$(printf '%s' "$MG_ROW" | cut -d'|' -f2); MG_CMD=$(printf '%s' "$MG_ROW" | cut -d'|' -f3-)
    case "$GATE" in
      *"$MG_CMD"*) MAIN_ROW_EV="main-gates.txt row for ${SLUG##*/}: already contained in --gate";;
      *)
        say "--gate does not contain the main-gates.txt row for ${SLUG##*/}; running it too: $MG_CMD"
        if [ "$DRY" = 1 ]; then MAIN_ROW_EV="main-gates.txt row for ${SLUG##*/} (dry run: not run): $MG_CMD"
        else
          MG_LOG="$GATE_LOG.row"
          if [ "$MG_VENTURE" != "-" ] && [ -x "${AFX_REMOTE_GATE:-$_AFX_LAND_DIR/afx-remote-gate.sh}" ]; then
            MG_TRY=0; MG_INFRA=""
            while :; do
              MG_TRY=$((MG_TRY+1))
              ( cd "$ROOT" || exit 99; AFX_GATE_INCLUDE_DOCS="${AFX_GATE_INCLUDE_DOCS:-1}" bash "${AFX_REMOTE_GATE:-$_AFX_LAND_DIR/afx-remote-gate.sh}" "$MG_VENTURE" "$BRANCH" "export CI=true; $MG_CMD" ) > "$MG_LOG" 2>&1; MGRC=$?; MG_WHERE="on Replit ($MG_VENTURE)"
              if { [ "$MGRC" -eq 255 ] || [ "$MGRC" -eq 97 ]; } && [ "$MG_TRY" -lt 2 ]; then
                say "main-gates row exit $MGRC = infrastructure (ssh/remote transport lost), not a test failure: retrying once"; MG_INFRA=" (first attempt exit $MGRC = infrastructure, retried once)"; continue
              fi
              break
            done
            { [ "$MGRC" -eq 255 ] || [ "$MGRC" -eq 97 ]; } && MG_WHERE="on Replit ($MG_VENTURE), infrastructure failure twice: the transport to the repl was lost, not a test failure"
          else
            ( cd "$ROOT" || exit 99; bash -o pipefail -c "$MG_CMD" ) > "$MG_LOG" 2>&1; MGRC=$?; MG_WHERE="locally"
          fi
          tail -n 8 "$MG_LOG" | sed 's/^/    | /'
          [ "$MGRC" -ne 0 ] && { rm -f "$MG_LOG"; die 4 "the repo's main-gates.txt row failed $MG_WHERE (exit $MGRC): $MG_CMD. That is the minimum gate for ${SLUG##*/}. The branch is pushed but nothing was merged."; }
          rm -f "$MG_LOG"; MAIN_ROW_EV="main-gates.txt row for ${SLUG##*/} ran $MG_WHERE, EXIT: 0: $MG_CMD${MG_INFRA:-}"
          say "main-gates row EXIT: 0 ($MG_WHERE)"
        fi;;
    esac
  fi
fi

# 5 PR + evidence
[ -z "$TITLE" ] && TITLE=$(git log -1 --format=%s)
# Run report: when this worktree was started from an Intent Card (AFX Desktop), the card's report goes into the PR body, BEFORE the
# Evidence section (afx-pr-ready.sh reads only what follows the Evidence heading, so a [BLOCKED] line quoting a non-zero EXIT in the
# report is shown to the reviewer in full and cannot be mistaken for a failed gate). No card, no shim, or any error: no section.
RUN_REPORT=""
_INTENT="${AFX_INTENT_BIN:-$HOME/.afx/bin/afx-intent}"
if [ -x "$_INTENT" ]; then RUN_REPORT=$(afx_platform_timeout 20 "$_INTENT" report 2>/dev/null) || RUN_REPORT=""; fi
{
  [ -n "$BODY_FILE" ] && [ -f "$BODY_FILE" ] && cat "$BODY_FILE" || printf '## Summary\n%s\n' "$(git log --format='- %s' "origin/$BASE..HEAD" | head -20)"
  if [ -n "$RUN_REPORT" ]; then
    printf '\n## Run report (Intent Card)\n'
    printf 'Written by `afx-intent report` from this session'"'"'s Intent Card. [BUILT] means the criterion'"'"'s literal gate exited 0 and the exit was recorded; [PARTIAL] and [BLOCKED] are stated limits, not failures; [OPEN] was never verified.\n\n```text\n%s\n```\n' "$RUN_REPORT"
  fi
  printf '\n## Evidence (written by afx-land.sh)\n'
  printf -- '- base: origin/%s %s%s\n' "$BASE" "$BASE_SHA" "$([ "$MERGED_BASE" = 1 ] && echo ' (merged into this branch before gating)')"
  printf -- '- head: %s\n' "$HEAD_SHA"
  printf -- '- gate: %s\n' "$GATE_DESC"
  printf -- '- EXIT: %s\n' "$GRC"
  [ -n "$MAIN_ROW_EV" ] && printf -- '- %s\n' "$MAIN_ROW_EV"
  [ "$FIXES_MAIN" = 1 ] && printf -- '- main health: this change is marked as the fix for a red main (--fixes-main)\n'
  [ -n "$RATCHET_EV" ] && { case "$RATCHET_EV" in SKIPPED*) printf -- '- error ratchet: %s\n' "$RATCHET_EV";; *) printf -- '- error ratchet (EXIT: 0):\n'; printf '%s\n' "$RATCHET_EV" | sed 's/^/    /';; esac; }
  printf -- '- machine: %s, author: %s\n' "$(afx_platform_os)" "${GIT_AUTHOR_NAME:-$(git config user.name)}"
  printf '\n```\n'; tail -n 12 "$GATE_LOG"; printf '```\n'
  printf '\n%s\n' "Generated with afx-land.sh"
} > "$GATE_LOG.body"
if [ "$DRY" = 1 ]; then say "dry run: PR body would end with the Evidence section above; stopping before any remote write."; exit 0; fi
PRN=$("$GH" pr list -R "$SLUG" --head "$BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null)
if [ -z "$PRN" ] || [ "$PRN" = "null" ]; then
  PRN=$("$GH" pr create -R "$SLUG" --base "$BASE" --head "$BRANCH" --title "$TITLE" --body-file "$GATE_LOG.body" 2>/dev/null | grep -o '[0-9]*$' | tail -1)
  [ -z "$PRN" ] && die 6 "could not create the pull request"
  say "opened PR #$PRN"
else
  "$GH" api -X PATCH "repos/$SLUG/pulls/$PRN" -F "body=@$GATE_LOG.body" >/dev/null 2>&1 || say "could not refresh the PR body (continuing)"
  say "reusing PR #$PRN"
fi

# 6 rules (give GitHub a moment to compute mergeability)
i=0; while [ $i -lt 20 ]; do
  m=$("$GH" api "repos/$SLUG/pulls/$PRN" --jq '.mergeable' 2>/dev/null); [ "$m" = "true" ] || [ "$m" = "false" ] && break; i=$((i+1)); sleep 3
done
"$_AFX_LAND_DIR/afx-pr-ready.sh" --repo "$SLUG" --pr "$PRN" > "$GATE_LOG.rules" 2>&1; RRC=$?
# A PR that changes the readiness rules must also be judged by its OWN new rules (bootstrap gap found 2026-10-08: the PR that made the
# registry a protected path was merged under the old rules). If this branch carries its own copy, it must say READY too.
OWN_RULES="$ROOT/scripts/afx-guard/afx-pr-ready.sh"
if [ -f "$OWN_RULES" ] && ! cmp -s "$OWN_RULES" "$_AFX_LAND_DIR/afx-pr-ready.sh"; then
  AFX_GUARD_DIR="$ROOT/scripts/afx-guard" bash "$OWN_RULES" --repo "$SLUG" --pr "$PRN" > "$GATE_LOG.rules2" 2>&1; RRC2=$?
  if [ "$RRC2" -ne 0 ]; then RRC=$RRC2; echo "(the readiness rules in this branch are stricter than the installed ones:)" >> "$GATE_LOG.rules"; cat "$GATE_LOG.rules2" >> "$GATE_LOG.rules"; fi
  rm -f "$GATE_LOG.rules2"
fi
# Owner approval in the command (2026-10-14): when the run is prefixed with AFX_OWNER_OK="<owner's words>" (the policy hook has
# already checked those words against what the owner typed in the last 24h) and the only thing missing is the owner-ok label,
# add the label, log it to _readiness/OVERRIDES.log and judge the rules again. Without AFX_OWNER_OK nothing changes.
if [ "$RRC" -ne 0 ] && [ -n "${AFX_OWNER_OK:-}" ] && grep -q "label owner-ok needed" "$GATE_LOG.rules"; then
  if "$GH" pr edit "$PRN" -R "$SLUG" --add-label owner-ok >/dev/null 2>&1; then
    say "owner approval given (AFX_OWNER_OK): added the label owner-ok to PR #$PRN"
    OVR="${AFX_READINESS_DIR:-$_AFX_LAND_DIR/../../ops/readiness/_readiness}/OVERRIDES.log"
    [ -d "$(dirname "$OVR")" ] && printf '%s\t%s\towner-ok label via afx-land\t%s#%s\t%s\n' "$(date -u '+%F %H:%M')" "${AFX_SESSION_NAME:-agent}" "$SLUG" "$PRN" "$AFX_OWNER_OK" >> "$OVR"
    "$_AFX_LAND_DIR/afx-pr-ready.sh" --repo "$SLUG" --pr "$PRN" > "$GATE_LOG.rules" 2>&1; RRC=$?
  fi
fi
sed 's/^/    | /' "$GATE_LOG.rules" | head -12; rm -f "$GATE_LOG.rules"
[ "$RRC" -ne 0 ] && die 5 "rules say not ready (see above). The branch and PR #$PRN stay open; for a protected change, re-run prefixed with AFX_OWNER_OK=\"<the owner's words approving it>\" (adds the label owner-ok) or ask the owner."

# 6b per-repo landing lock (2026-10-15: concurrent landings were each tested before the others merged, so main went red). Only one
# afx-land.sh per repo reaches the merge at a time (afx-lock.sh: a dead holder is reclaimed, a hung one expires). After taking it:
# fetch; if origin/<base> moved while this run was gating or waiting, merge it in and re-run the WHOLE flow (this script re-executes
# itself holding the lock, so the gate, the ratchet and the rules judge the code that will really be on main), at most 3 times.
# AFX_LAND_NO_LOCK=1 skips it; AFX_LAND_LOCK_DIR, AFX_LAND_LOCK_WAIT_S and AFX_LAND_LOCK_MAX_AGE_S tune it.
if [ -z "${AFX_LAND_NO_LOCK:-}" ]; then
  LOCK_FILE="${AFX_LAND_LOCK_DIR:-$HOME/.afx/locks}/land-${SLUG##*/}.lock"
  mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || die 6 "cannot create the landing lock directory $(dirname "$LOCK_FILE")"
  export AFX_LOCK_FILE="$LOCK_FILE"
  AFX_LOCK_WAIT_S="${AFX_LAND_LOCK_WAIT_S:-10800}"; AFX_LOCK_MAX_AGE_S="${AFX_LAND_LOCK_MAX_AGE_S:-5400}"
  . "$_AFX_LAND_DIR/afx-lock.sh"
  if [ "${AFX_LAND_LOCK_HELD:-}" = "$LOCK_FILE" ] && [ "$(awk '{print $2}' "$LOCK_FILE" 2>/dev/null)" = "$$" ]; then
    _AFX_LOCK_HELD="$LOCK_FILE"   # this process was exec'd by the previous pass, which already holds the lock (same pid)
  else
    say "landing lock for ${SLUG##*/}: waiting for it if another landing holds it ($LOCK_FILE)"
    afx_lock_acquire "land-${SLUG##*/}" "$BRANCH" || die 6 "could not get the landing lock for ${SLUG##*/} (another landing holds it; see above). Nothing was merged; re-run later."
    trap 'rm -f "$GATE_LOG" "$GATE_LOG.body"; afx_lock_release' EXIT
  fi
  afx_platform_timeout 180 git fetch -q origin || die 6 "git fetch under the landing lock failed"
  if ! git merge-base --is-ancestor "origin/$BASE" HEAD; then
    N="${AFX_LAND_REEXEC:-0}"
    [ "$N" -ge 3 ] && die 5 "origin/$BASE keeps moving while landing (3 re-runs). Re-run afx-land.sh when other landings settle."
    say "origin/$BASE moved while this landing waited: merging it and re-running the gate under the lock (pass $((N+1)))"
    if ! git merge --no-edit -q "origin/$BASE" >/dev/null 2>&1; then
      git merge --abort >/dev/null 2>&1
      die 3 "merge conflict with origin/$BASE under the landing lock. The merge was aborted and nothing was changed. The author resolves it, then re-run."
    fi
    export AFX_LAND_LOCK_HELD="$LOCK_FILE" AFX_LAND_REEXEC=$((N+1))
    exec bash "$SELF" "${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}"
  fi
fi

# 7 merge + verify
"$GH" pr merge "$PRN" -R "$SLUG" --merge >/dev/null 2>&1 || die 6 "gh pr merge failed for #$PRN"
afx_platform_timeout 120 git fetch -q origin || die 6 "fetch after merge failed"
git merge-base --is-ancestor "$HEAD_SHA" "origin/$BASE" || die 6 "PR #$PRN reports merged but $HEAD_SHA is not in origin/$BASE"
MERGE_SHA=$(git rev-parse "origin/$BASE")

# 8 cleanup
DELETED="no"
if [ "$KEEP" = 0 ]; then
  case "$BRANCH" in
    rescue/*|preserve/*|archive/*|backup/*|salvage/*) say "keeping $BRANCH (protected prefix)";;
    *) git push -q origin --delete "$BRANCH" 2>/dev/null && DELETED="yes";;
  esac
fi
# 7b post-merge verification (2026-10-15): run the repo's main-gates.txt row against the merged main in the background (on its Replit
# host, via afx-main-health.sh --only <repo>, recorded in MAIN_HEALTH.tsv). A RED result writes ~/.afx/alerts/<repo>-<sha>.txt, sends a
# desktop notification and shows in the afx-where-am-i banner. Never changes the exit code; AFX_LAND_NO_VERIFY=1 skips it.
MH="${AFX_MAIN_HEALTH:-$_AFX_LAND_DIR/afx-main-health.sh}"; VERIFY="skipped"
if [ -z "${AFX_LAND_NO_VERIFY:-}" ] && [ -x "$MH" ]; then
  MH_GATES="${AFX_MAIN_GATES:-$_AFX_LAND_DIR/main-gates.txt}"
  if [ -f "$MH_GATES" ] && awk -F'|' -v r="${SLUG##*/}" '$1==r && $2!="-"{f=1} END{exit f?0:1}' "$MH_GATES"; then
    MH_LOG="${AFX_LAND_VERIFY_LOG:-${TMPDIR:-/tmp}/afx-post-merge-${SLUG##*/}-${MERGE_SHA:0:12}.log}"
    ( nohup "$MH" --only "${SLUG##*/}" --force > "$MH_LOG" 2>&1 < /dev/null & ) >/dev/null 2>&1
    VERIFY="started in the background (log: $MH_LOG)"
  fi
fi
say "post-merge verification: $VERIFY"
say "LANDED: branch=$BRANCH pr=#$PRN origin/$BASE=$MERGE_SHA gate=EXIT $GRC remote-branch-deleted=$DELETED"
# 9 opt-in advisory afx-shots reminder (never gates, never changes the exit code)
if [ "$SHOTS" = 1 ]; then
  if [ ! -f "$ROOT/shots.config.json" ]; then say "shots: --shots given but this repo has no shots.config.json: nothing to do (docs/AFX_SHOTS.md 'Adding a venture')"
  elif echo "$CHANGED" | grep -Evq '(\.mdc?$|^docs/|/docs/)'; then
    SHOTS_V=$(sed -n 's/.*"venture"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/shots.config.json" | head -1)
    SHOTS_BIN="$_AFX_LAND_DIR/../afx-shots/afx-shots.mjs"; [ -f "$SHOTS_BIN" ] || SHOTS_BIN="<hub>/scripts/afx-shots/afx-shots.mjs"
    say "shots (advisory): the merged diff touches app files. Refresh the reference screenshots from a fresh worktree of origin/$BASE:"
    say "shots:   node \"$SHOTS_BIN\" run ${SHOTS_V:-<venture>} --repo <fresh worktree of origin/$BASE> --changed-since $BASE_SHA --diff"
  else say "shots: the merged diff is docs-only: no screenshot refresh needed"; fi
fi
say "next: run 'afx-land.sh --cleanup' in this worktree: it removes the worktree and local branch after confirming $HEAD_SHA is in origin/$BASE. In a main checkout, switch to $BASE with afx-sync-clones.sh."
exit 0
