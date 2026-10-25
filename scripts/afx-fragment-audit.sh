#!/bin/bash
# afx-fragment-audit.sh: find code that exists ONLY on this machine (unpushed commits, stashes,
# dirty or untracked files, worktrees) across every repo under the clones folder, plus
# stray git clones elsewhere.
#   scripts/afx-guard/afx-fragment-audit.sh [root]
#
# Portable: macOS, Linux (Replit repls) and Windows (Git Bash). Also flags
# ad-hoc, machine-local-only audit/sweep output folders (dated top-level
# folders that never made it into a tracked doc) — see A-XPLAT findings from
# the Windows/Lenovo session, 2026-09-27: sweep output there landed in
# a machine-local sync folder and was never committed.
set -u
_AFX_FA_DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
. "$_AFX_FA_DIR/afx-platform.sh"
ROOT="${1:-$(afx_platform_clones_root)}"
find "$ROOT" -maxdepth 8 \( -name node_modules -o -name .claude -o -name Pods -o -name build \) -prune -o -type d -name .git -print 2>/dev/null | sed 's#/\.git$##' | while IFS= read -r r; do
  n=$(basename "$r")
  [ "$n" = "." ] && n=$(basename "$(cd "$r" && pwd)")
  afx_platform_timeout 120 git -C "$r" fetch -q --all --prune 2>/dev/null
  git -C "$r" worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r wt; do
    [ -d "$wt" ] || { echo "$n MISSING-WORKTREE $wt"; continue; }
    br=$(git -C "$wt" branch --show-current 2>/dev/null); [ -z "$br" ] && br="(detached $(git -C "$wt" rev-parse --short HEAD))"
    d=$(git -C "$wt" status --porcelain -uno 2>/dev/null | wc -l | tr -d ' ')
    u=$(git -C "$wt" status --porcelain 2>/dev/null | grep -c '^??')
    [ "$d" != 0 ] && echo "$n DIRTY $d tracked-files in $wt [$br]"
    [ "$u" != 0 ] && echo "$n UNTRACKED $u files in $wt [$br]"
  done
  git -C "$r" for-each-ref --format='%(refname:short)' refs/heads | while IFS= read -r b; do
    c=$(git -C "$r" rev-list --count "$b" --not --remotes 2>/dev/null)
    [ "${c:-0}" != 0 ] && echo "$n UNPUSHED $c commits on branch $b"
  done
  s=$(git -C "$r" stash list 2>/dev/null | wc -l | tr -d ' ')
  [ "$s" != 0 ] && echo "$n STASHES $s"
  [ -f "$r/.gitattributes" ] || echo "$n NO-GITATTRIBUTES (line-ending/binary handling is undefined across Mac/Linux/Windows checkouts)"
done

# Ad-hoc sweep/audit output folders: a dated top-level folder next to the clones
# (e.g. FLEET_SYNC_2026-09-24) that is not itself a git repo is a sign findings
# went to a machine-local folder instead of a tracked doc/PR. Report it; do not
# delete it (the owner reviews before deciding to fold it into a doc PR).
PARENT="$(cd "$ROOT/.." 2>/dev/null && pwd)"
if [ -n "$PARENT" ] && [ -d "$PARENT" ]; then
  find "$PARENT" -maxdepth 1 -type d \( -iname "*sync*" -o -iname "*sweep*" -o -iname "*audit*" -o -iname "*FLEET_SYNC*" -o -iname "*_AFX_Actions*" -o -iname "*action*" -o -regex '.*[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}.*' \) 2>/dev/null | while IFS= read -r d; do
    [ -d "$d/.git" ] && continue
    echo "AD-HOC-OUTPUT $d is not a git repo and not under $ROOT — findings here are machine-local-only until landed as a tracked doc/PR"
  done
fi

# Git config hygiene: safe.directory / worktree / remote entries pointing at
# paths that no longer exist, or that are explicitly forbidden (a machine's
# own "neverWorkIn" list in afx-projects.json, or a known-legacy path like
# C:\afx on the Lenovo). Stale entries are metadata debris, not urgent, but
# they are exactly the fingerprint of the "worked outside the canonical clone"
# mistake the portfolio's rules exist to prevent (Windows/Lenovo finding,
# 2026-09-27: dozens of stale `C:/afx/...` safe.directory entries, folder
# itself long gone).
git config --global --get-all safe.directory 2>/dev/null | while IFS= read -r p; do
  case "$(afx_platform_os)" in
    windows) case "$p" in [Cc]:[/\\]afx*) echo "STALE-CONFIG safe.directory=$p (forbidden legacy path, on $(afx_platform_os))";; esac ;;
  esac
  [ -d "$p" ] || echo "STALE-CONFIG safe.directory=$p (path does not exist)"
done

# Stale worktree ADMIN entries: a repo's .git/worktrees/<name>/gitdir file
# points back at the worktree's own .git file. `git worktree list` already
# surfaces most of this (MISSING-WORKTREE, above), but that requires the
# worktree to still be registered on a HEAD-ful checkout; walking the raw
# admin dirs directly also catches one whose parent repo checkout itself
# moved/was deleted (so `git -C "$r" worktree list` can't even run).
find "$ROOT" -maxdepth 6 \( -name node_modules -o -name Pods -o -name build \) -prune -o -type d -path "*/.git/worktrees/*" -print 2>/dev/null | while IFS= read -r wtadmin; do
  [ -f "$wtadmin/gitdir" ] || continue
  target="$(sed -n 's/\.git$//p' "$wtadmin/gitdir" 2>/dev/null)"
  [ -n "$target" ] && [ ! -d "$target" ] && echo "STALE-WORKTREE-ADMIN $wtadmin -> $target (directory gone; git worktree prune)"
done
