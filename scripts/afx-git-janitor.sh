#!/bin/bash
# afx-git-janitor.sh: automatic git housekeeping so nobody does it by hand.
#
#   afx-git-janitor.sh [--root <clones-root>] [--apply] [--min-age-hours N] [--no-worktrees]
#
# For every git clone directly under the clones root:
#   1. git fetch --prune origin
#   2. local branches whose tip is already in origin/<base>   -> git branch -d   (safe delete only)
#   3. remote branches whose tip is in origin/<base>, or whose tip equals the head of a MERGED pull request
#      (squash and rebase merges)                            -> git push origin --delete
#   4. worktrees whose branch is merged and clean            -> afx-worktree-clean.sh --fleet --apply-fleet
# DRY RUN unless --apply. Never touches: the base branch, staging, branches checked out in any worktree,
# dependabot/* (owner reviews those), rescue/ preserve/ archive/ backup/ salvage/ recovered-* prefixes,
# refs/afx snapshots, or any branch with a commit newer than --min-age-hours (default 24: a live session).
# Output ends with: JANITOR local_deleted=<n> remote_deleted=<n> kept=<n> mode=<dry-run|apply>
# Run on a schedule with afx-git-janitor.plist.template. Portable: plain git + optional gh.
set -u
DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
. "$DIR/afx-platform.sh"
ROOT=""; APPLY=0; MINAGE=24; WT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2;;
    --apply) APPLY=1; shift;;
    --min-age-hours) MINAGE="$2"; shift 2;;
    --no-worktrees) WT=0; shift;;
    -h|--help) sed -n 2,19p "$0"; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
if [ -z "$ROOT" ]; then
  _mc=$(sed -n 's/^root=//p' "$HOME/.claude/hooks/afx-guard/machine.conf" 2>/dev/null | head -1)
  _cm=$(afx_config_get clonesRootMac)
  ROOT="${AFX_CLONES_ROOT:-${_mc:-${_cm/#\~/$HOME}}}"
fi
ROOT="${ROOT/#\~/$HOME}"
[ -d "$ROOT" ] || { echo "JANITOR: clones root not found: $ROOT" >&2; exit 3; }

LD=0; RD=0; KEEP=0
SEEN=""
protected() {  # protected <branch name without origin/>
  case "$1" in
    HEAD|main|master|staging|dependabot/*|rescue/*|preserve/*|archive/*|backup/*|salvage/*|recovered-*) return 0;;
  esac
  return 1
}
old_enough() {  # old_enough <commit-ish>: last commit older than MINAGE hours
  local t now; t=$(git log -1 --format=%ct "$1" 2>/dev/null) || return 1
  now=$(date +%s); [ $(( now - t )) -ge $(( MINAGE * 3600 )) ]
}

for repo in "$ROOT"/*/; do
  repo="${repo%/}"
  { [ -d "$repo/.git" ] || [ -f "$repo/.git" ]; } || continue
  name=$(basename "$repo")
  cd "$repo" || continue
  # the same repo can appear under two folder names (alias/symlink): visit each git dir once
  gd=$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || continue
  case "$SEEN" in *"|$gd|"*) echo "SKIP $name: same repo as an earlier entry"; continue;; esac
  SEEN="$SEEN|$gd|"
  git fetch -q --prune origin 2>/dev/null || { echo "SKIP $name: fetch failed"; continue; }
  base=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  [ -n "$base" ] || base=main
  git rev-parse -q --verify "origin/$base" >/dev/null || { echo "SKIP $name: no origin/$base"; continue; }
  checked_out=$(git worktree list --porcelain | sed -n 's#^branch refs/heads/##p')
  slug=$(git remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##')

  # 2. local branches
  git for-each-ref --format='%(refname:short)' refs/heads | while IFS= read -r b; do
    protected "$b" && continue
    [ "$b" = "$base" ] && continue
    printf '%s\n' "$checked_out" | grep -qxF -- "$b" && continue
    git merge-base --is-ancestor "$b" "origin/$base" 2>/dev/null || continue
    old_enough "$b" || continue
    if [ "$APPLY" = 1 ]; then
      git branch -d "$b" >/dev/null 2>&1 && echo "LOCAL-DELETED $name $b" || echo "LOCAL-KEPT $name $b (git refused)"
    else
      echo "WOULD-DELETE-LOCAL $name $b"
    fi
  done > "${TMPDIR:-/tmp}/afx-janitor.$$" 
  cat "${TMPDIR:-/tmp}/afx-janitor.$$"
  LD=$(( LD + $(grep -c -E '^(LOCAL-DELETED|WOULD-DELETE-LOCAL)' "${TMPDIR:-/tmp}/afx-janitor.$$") ))
  rm -f "${TMPDIR:-/tmp}/afx-janitor.$$"

  # 3. remote branches
  while IFS= read -r ref; do
    b="${ref#origin/}"
    protected "$b" && continue
    [ "$b" = "$base" ] && continue
    old_enough "$ref" || { KEEP=$((KEEP+1)); continue; }
    merged=0
    if git merge-base --is-ancestor "$ref" "origin/$base" 2>/dev/null; then
      merged=1
    elif command -v gh >/dev/null 2>&1 && [ -n "$slug" ]; then
      tip=$(git rev-parse "$ref")
      n=$(gh pr list --repo "$slug" --state merged --head "$b" --json headRefOid --jq "[.[]|select(.headRefOid==\"$tip\")]|length" 2>/dev/null || echo 0)
      [ "${n:-0}" -ge 1 ] 2>/dev/null && merged=1
    fi
    if [ "$merged" = 1 ]; then
      if [ "$APPLY" = 1 ]; then
        git push -q origin --delete "$b" 2>/dev/null && { echo "REMOTE-DELETED $name $b"; RD=$((RD+1)); } || { echo "REMOTE-KEPT $name $b (push refused)"; KEEP=$((KEEP+1)); }
      else
        echo "WOULD-DELETE-REMOTE $name $b"; RD=$((RD+1))
      fi
    else
      KEEP=$((KEEP+1))
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/remotes/origin)
done

# 4. worktrees
if [ "$WT" = 1 ] && [ -f "$DIR/afx-worktree-clean.sh" ]; then
  if [ "$APPLY" = 1 ]; then
    bash "$DIR/afx-worktree-clean.sh" --fleet "$ROOT" --apply-fleet --min-age-hours "$MINAGE" 2>&1 | grep -E '^(REMOVED|KEEP)' | sed 's/^/WORKTREE /'
  else
    bash "$DIR/afx-worktree-clean.sh" --fleet "$ROOT" --min-age-hours "$MINAGE" 2>&1 | grep -E '^(WOULD|REMOVED|KEEP)' | sed 's/^/WORKTREE /'
  fi
fi

echo "JANITOR local_deleted=$LD remote_deleted=$RD kept=$KEEP mode=$([ "$APPLY" = 1 ] && echo apply || echo dry-run)"
exit 0
