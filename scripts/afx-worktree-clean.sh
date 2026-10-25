#!/bin/bash
# afx-worktree-clean.sh: list every worktree under a repo, flag which ones are
# safe to remove (branch merged into the base branch, or its remote branch is
# gone, AND the working tree is clean), and remove only those. A dirty
# worktree, or one on a branch that's still live, is reported and left alone
# — this script never deletes anything it isn't sure about.
#
#   scripts/afx-guard/afx-worktree-clean.sh [repo-path] [--base <branch>] [--dry-run]
#                                           [--keep NAME]... [--min-age-hours N]
#   scripts/afx-guard/afx-worktree-clean.sh --fleet <clones-root> [--apply-fleet] [--keep NAME]... [--min-age-hours N]
#   scripts/afx-guard/afx-worktree-clean.sh --orphans <clones-root> [--wt-subdir .claude/worktrees]     READ-ONLY report
#
# --keep NAME          never remove a worktree whose directory name or branch equals NAME (repeatable).
# --min-age-hours N    never remove a worktree with activity in the last N hours (default 24): a merged,
#                      clean worktree can still be one a running session is about to use. Activity = the
#                      newest of its last commit and its git HEAD/index/reflog files. Use 0 to disable.
# --fleet ROOT         run over every git clone directly under ROOT. This is a DRY RUN unless
#                      --apply-fleet is also given: a fleet-wide real run removed worktrees other
#                      sessions were using on 2026-10-08, so it must be asked for explicitly.
#
# --orphans ROOT      READ-ONLY (never removes anything). For every git clone directly under ROOT, list each folder under
#                      <clone>/.claude/worktrees that git no longer knows as a worktree (the "Directory not empty" leftover that
#                      `git worktree remove` can leave behind, usually a pnpm node_modules tree), with the one-line command that
#                      disposes of it (Trash, never rm -rf) and the count. Exit 0 always; the last line is ORPHANS=<n>.
#
# Default repo-path is the current directory. Default base branch is
# origin/HEAD's default branch (falls back to origin/main). --dry-run prints
# what WOULD be removed without removing anything.
#
# Portable: macOS, Linux and Windows/Git Bash — plain `git` plumbing only.
# This is the generalized version of the "remove merged worktrees" advice
# afx-preflight.sh and afx-fragment-audit.sh already print as a hint; this
# script is what actually does it, safely. It complements (does not replace)
# windows/afx-worktree-remove.ps1, which handles ONE Windows-specific
# deletion failure (pnpm hardlink paths) once a worktree has already been
# identified as safe to remove — that logic can be layered under this
# script's removal step on Windows if needed.
set -u
DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "$0")" && pwd)}"
. "$DIR/afx-platform.sh"

REPO="."
BASE=""
DRY_RUN=0
KEEP=""          # newline-separated names
MIN_AGE_H=24
FLEET=""
APPLY_FLEET=0
ORPHANS=""
WT_SUBDIR=".claude/worktrees"
ARGS_FWD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --keep) KEEP="$KEEP
$2"; shift 2 ;;
    --min-age-hours) MIN_AGE_H="$2"; shift 2 ;;
    --fleet) FLEET="$2"; shift 2 ;;
    --apply-fleet) APPLY_FLEET=1; shift ;;
    --orphans) ORPHANS="$2"; shift 2 ;;
    --wt-subdir) WT_SUBDIR="$2"; shift 2 ;;
    *) REPO="$1"; shift ;;
  esac
done
case "$MIN_AGE_H" in ''|*[!0-9]*) echo "afx-worktree-clean: --min-age-hours needs a whole number" >&2; exit 64 ;; esac

if [ -n "$ORPHANS" ]; then
  [ -d "$ORPHANS" ] || { echo "not a directory: $ORPHANS" >&2; exit 2; }
  n_orph=0
  for d in "$ORPHANS"/*/; do
    d="${d%/}"
    [ -d "$d/.git" ] || continue                       # a real clone (a worktree has a .git FILE and is not a clone root)
    [ -d "$d/$WT_SUBDIR" ] || continue
    reg="$(git -C "$d" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | while IFS= read -r w; do (cd "$w" 2>/dev/null && pwd -P) || echo "$w"; done)"
    for w in "$d/$WT_SUBDIR"/*/ "$d/$WT_SUBDIR"/.[!.]*/; do
      w="${w%/}"; [ -d "$w" ] || continue
      real="$(cd "$w" && pwd -P)"
      if printf '%s\n' "$reg" | grep -qxF -- "$real"; then continue; fi
      cnt=$(ls -A "$w" 2>/dev/null | wc -l | tr -d ' '); nm="no"; [ -d "$w/node_modules" ] && nm="yes"
      gitfile="no"; [ -e "$w/.git" ] && gitfile="yes"
      n_orph=$((n_orph+1))
      echo "ORPHAN  $w [repo=$(basename "$d") entries=$cnt node_modules=$nm .git=$gitfile] not a registered worktree of $(basename "$d")"
      echo "        dispose (after checking nothing in it is unpushed): $(afx_platform_trash_cmd "$w" "$d")"
    done
  done
  echo "ORPHANS=$n_orph"
  exit 0
fi

if [ -n "$FLEET" ]; then
  [ -d "$FLEET" ] || { echo "not a directory: $FLEET" >&2; exit 2; }
  [ "$APPLY_FLEET" = 1 ] || echo "afx-worktree-clean: --fleet without --apply-fleet is a DRY RUN; nothing will be removed"
  for d in "$FLEET"/*/; do
    [ -e "${d}.git" ] || continue
    set -- "${d%/}" --min-age-hours "$MIN_AGE_H"
    [ "$APPLY_FLEET" = 1 ] || set -- "$@" --dry-run
    [ -n "$BASE" ] && set -- "$@" --base "$BASE"
    OLDIFS="$IFS"; IFS='
'
    for k in $KEEP; do [ -n "$k" ] && set -- "$@" --keep "$k"; done
    IFS="$OLDIFS"
    bash "$DIR/afx-worktree-clean.sh" "$@"
  done
  exit 0
fi

is_kept() {  # $1 worktree dir name, $2 branch
  OLDIFS="$IFS"; IFS='
'
  for k in $KEEP; do
    if [ -n "$k" ] && { [ "$k" = "$1" ] || [ "$k" = "$2" ]; }; then IFS="$OLDIFS"; return 0; fi
  done
  IFS="$OLDIFS"; return 1
}
is_recent() {  # $1 worktree path: 0 (true) when it saw activity within MIN_AGE_H hours
  [ "$MIN_AGE_H" = 0 ] && return 1
  _gd=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  _ct=$(git -C "$1" log -1 --format=%ct 2>/dev/null); _now=$(date +%s)
  [ -n "$_ct" ] && [ $(( _now - _ct )) -lt $(( MIN_AGE_H * 3600 )) ] && return 0
  for _f in "$_gd/HEAD" "$_gd/index" "$_gd/logs/HEAD"; do
    [ -e "$_f" ] && [ -n "$(find "$_f" -mmin -$(( MIN_AGE_H * 60 )) 2>/dev/null)" ] && return 0
  done
  return 1
}
REPO="$(cd "$REPO" && pwd)" || { echo "not a directory: $REPO" >&2; exit 2; }
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $REPO" >&2; exit 2; }

if [ -z "$BASE" ]; then
  BASE=$(git -C "$REPO" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  [ -z "$BASE" ] && BASE=main
fi
afx_platform_timeout 60 git -C "$REPO" fetch -q origin "$BASE" --prune 2>/dev/null

MAIN_WT="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)"
echo "afx-worktree-clean: repo=$REPO base=origin/$BASE dry_run=$DRY_RUN min_age_hours=$MIN_AGE_H"

# A-XPLAT-13: `awk '{print $N}'` splits on whitespace, so a worktree path
# containing a space ("How To Raise") was silently truncated to "How" here —
# nothing errored, the tool just reported/acted on the wrong path. Extract
# "everything after the 'worktree ' prefix" with sed instead, exactly like
# afx-fragment-audit.sh / afx-preserve-all.sh already do. (Also fixed
# independently on main by hub #206 — same content, this keeps the comment.)
git -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r wt; do
  [ "$wt" = "$MAIN_WT" ] && continue   # never touch the primary checkout
  if [ ! -d "$wt" ]; then
    echo "MISSING $wt (registered but the directory is gone — 'git worktree prune' will clear this)"
    continue
  fi

  BRANCH=$(git -C "$wt" branch --show-current 2>/dev/null)
  DIRTY=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

  if [ "${DIRTY:-0}" != 0 ]; then
    echo "KEEP    $wt [branch=${BRANCH:-detached}] — $DIRTY dirty/untracked path(s), never auto-removed"
    continue
  fi
  if [ -z "$BRANCH" ]; then
    echo "KEEP    $wt [detached HEAD] — no branch to check merge/gone status against, review manually"
    continue
  fi

  # "Gone": the branch's upstream tracking ref no longer exists on the remote.
  GONE=0
  git -C "$wt" for-each-ref --format='%(upstream:track)' "refs/heads/$BRANCH" 2>/dev/null | grep -q '\[gone\]' && GONE=1

  # "Merged": every commit on this branch is already reachable from origin/$BASE.
  MERGED=0
  if git -C "$REPO" merge-base --is-ancestor "$BRANCH" "origin/$BASE" 2>/dev/null; then MERGED=1; fi

  if [ "$MERGED" = 1 ] || [ "$GONE" = 1 ]; then
    REASON="merged into origin/$BASE"; [ "$GONE" = 1 ] && REASON="remote branch gone"
    if is_kept "$(basename "$wt")" "$BRANCH"; then
      echo "KEEP    $wt [branch=$BRANCH] — $REASON, clean tree, but named by --keep"
      continue
    fi
    if is_recent "$wt"; then
      echo "KEEP    $wt [branch=$BRANCH] — $REASON, clean tree, but active within the last ${MIN_AGE_H}h (--min-age-hours)"
      continue
    fi
    if [ "$DRY_RUN" = 1 ]; then
      echo "WOULD-REMOVE $wt [branch=$BRANCH] — $REASON, clean tree"
      continue
    fi
    # gitignored env/key files are invisible to `git status` and would be deleted with the folder: keep a copy first.
    if ! SA_MSG=$(afx_platform_set_aside_secrets "$wt"); then
      echo "KEEP    $wt [branch=$BRANCH] — $REASON, but an env/key file could not be copied to the set-aside folder"
      continue
    fi
    [ -n "$SA_MSG" ] && echo "NOTE    $SA_MSG"
    if git -C "$REPO" worktree remove "$wt" 2>/tmp/afx-wt-clean-err.$$; then
      echo "REMOVED $wt [branch=$BRANCH] — $REASON"
    elif git -C "$REPO" worktree remove --force "$wt" 2>>/tmp/afx-wt-clean-err.$$; then
      echo "REMOVED $wt [branch=$BRANCH] — $REASON (needed --force; see A-XPLAT-1 if this becomes chronic on one machine)"
    else
      echo "FAILED-REMOVE $wt [branch=$BRANCH] — $REASON, but removal itself failed: $(cat /tmp/afx-wt-clean-err.$$ 2>/dev/null | tr '\n' ' ')"
    fi
    rm -f "/tmp/afx-wt-clean-err.$$"
  else
    echo "KEEP    $wt [branch=$BRANCH] — not merged into origin/$BASE and not marked gone"
  fi
done
