#!/bin/bash
# afx-preserve-all.sh: copy every piece of machine-local code to GitHub WITHOUT touching anyone's
# working tree, index, or branches. Safe to run while other sessions are working.
# Since 2026-10-13 it creates NO branches (the old archive/<machine>/snapshot-<worktree>-<time> branches reached 1,804):
#   - unpushed commits on a work branch -> the branch itself is pushed (origin/<branch>), nothing else.
#   - everything else goes to refs/afx/*, a ref namespace GitHub stores but does not list as branches, so it never shows up
#     in branch lists, counts or `git clone`:
#       refs/afx/snapshot/<machine>/<worktree>  uncommitted tracked + untracked files (respecting .gitignore), built from a
#                                               TEMPORARY index; ONE rolling ref per worktree, pushed only when the files changed
#       refs/afx/stash/<machine>/<n>            one rolling ref per stash slot
#       refs/afx/branch/<machine>/<branch>      only when the branch itself cannot be pushed (remote diverged, or it is the default branch)
#   - snapshots expire by themselves: when the worktree is clean again (the work was committed, and the branch is pushed above)
#     the ref is deleted; when the worktree is gone it is deleted 14 days after it was taken (AFX_SNAPSHOT_KEEP_DAYS).
#   - clones whose origin is not an AFX account (third-party tools such as ComfyUI) are skipped: we cannot push there.
# Read one back:  git fetch origin refs/afx/snapshot/<machine>/<worktree> && git diff HEAD FETCH_HEAD
# List them:      git ls-remote origin 'refs/afx/*'
#   scripts/afx-guard/afx-preserve-all.sh [machine-label] [root] [skip-path-substring]
#
# Portable: runs on macOS, Linux (Replit repls over SSH) and Windows (Git Bash).
# Every network call goes through afx_platform_timeout instead of a bare
# `timeout`, which is not guaranteed present on macOS or Windows/Git Bash.
set -u
_AFX_PA_DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
. "$_AFX_PA_DIR/afx-platform.sh"
MACH="${1:-$(afx_platform_os)}"; ROOT="${2:-$(afx_platform_clones_root)}"; SKIP="${3:-/nonexistent-skip/}"
TS=$(date +%Y%m%d-%H%M)
# 180s was too tight for a repo with several-to-tens-of-MB objects already in its
# history (confirmed on two repos, 2026-09-27): the
# push itself succeeds fine when run untimed, it just needs longer than 180s to
# transfer. None of these are anywhere near GitHub's 100MB hard limit -- that's a
# separate, unrelated failure mode (see a project's baseline-results.json
# incident) that this timeout bump does not and should not paper over.
PUSH_TIMEOUT="${AFX_PRESERVE_PUSH_TIMEOUT:-600}"
KEEP_DAYS="${AFX_SNAPSHOT_KEEP_DAYS:-14}"
OWNERS="${AFX_GH_OWNERS:-$(afx_owner_regex)}"   # origins we own; anything else is a third-party clone
find "$ROOT" -maxdepth 8 \( -name node_modules -o -name .claude -o -name Pods -o -name build \) -prune -o -type d -name .git -print 2>/dev/null | sed 's#/\.git$##' | while IFS= read -r r; do
  n=$(basename "$r")
  [ "$n" = "." ] && n=$(basename "$(cd "$r" && pwd)")
  url=$(git -C "$r" remote get-url origin 2>/dev/null)
  if ! printf '%s' "$url" | grep -qiE "$OWNERS"; then echo "$n SKIPPED third-party origin (nothing is pushed there)"; continue; fi
  DEF=$(git -C "$r" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##'); DEF="${DEF:-main}"
  # 1) unpushed branches: push the branch itself; a rolling archive copy only when that is not possible
  git -C "$r" for-each-ref --format='%(refname:short)' refs/heads | while IFS= read -r b; do
    c=$(git -C "$r" rev-list --count "$b" --not --remotes 2>/dev/null)
    [ "${c:-0}" = 0 ] && continue
    case "$b" in "$DEF"|main|master|staging) own=0;; *) own=1;; esac
    if [ "$own" = 1 ] && afx_platform_timeout "$PUSH_TIMEOUT" git -C "$r" push -q origin "refs/heads/$b:refs/heads/$b" 2>/dev/null; then
      echo "$n PUSHED $b ($c commits, as its own branch)"; continue
    fi
    dest="refs/afx/branch/$MACH/$(echo "$b" | tr ':' '-')"
    afx_platform_timeout "$PUSH_TIMEOUT" git -C "$r" push -q origin "+refs/heads/$b:$dest" 2>/dev/null && echo "$n PUSHED $b -> $dest ($c commits, rolling copy, not a branch)" || echo "$n PUSH-FAILED $b"
  done
  # 2) stashes: one rolling ref per stash slot
  i=0
  while git -C "$r" rev-parse -q --verify "stash@{$i}" >/dev/null 2>&1; do
    sha=$(git -C "$r" rev-parse "stash@{$i}")
    afx_platform_timeout "$PUSH_TIMEOUT" git -C "$r" push -q origin "+$sha:refs/afx/stash/$MACH/$i" 2>/dev/null && echo "$n STASH $i -> refs/afx/stash/$MACH/$i" || echo "$n STASH-PUSH-FAILED $i"
    i=$((i+1))
  done
  # 3) snapshot dirty/untracked worktrees via a temp index (worktree + real index untouched)
  git -C "$r" worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r wt; do
    [ -d "$wt" ] || continue
    case "$wt" in *"$SKIP"*) echo "$n SKIPPED $wt"; continue;; esac
    [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] && continue
    tmpidx=$(mktemp); cp "$(git -C "$wt" rev-parse --path-format=absolute --git-path index)" "$tmpidx" 2>/dev/null
    # source only: skip regenerable build output, native projects, logs and archives. .claude/worktrees is skipped because each
    # worktree gets its own snapshot: without this a main checkout's snapshot swallowed every worktree under it.
    GIT_INDEX_FILE="$tmpidx" git -C "$wt" add -A -- . ':!.claude/worktrees/**' ':!**/.gate-logs/**' ':!**/build/**' ':!**/build-sim*/**' ':!**/.build/**' ':!**/ios/**' ':!**/android/**' ':!**/DerivedData/**' ':!**/*.xcarchive/**' ':!**/*.log' ':!**/dist/**' ':!**/node_modules/**' >/dev/null 2>&1
    tree=$(GIT_INDEX_FILE="$tmpidx" git -C "$wt" write-tree 2>/dev/null)
    head=$(git -C "$wt" rev-parse HEAD)
    rm -f "$tmpidx"
    [ -z "$tree" ] && { echo "$n SNAPSHOT-FAILED $wt"; continue; }
    [ "$tree" = "$(git -C "$wt" rev-parse HEAD^{tree})" ] && continue
    wname=$(basename "$wt"); ref="refs/afx/snapshot/$MACH/$wname"
    # one rolling ref per worktree: skip the push when it already holds exactly these files
    prev=$(afx_platform_timeout 60 git -C "$r" ls-remote origin "$ref" 2>/dev/null | cut -f1)
    if [ -n "$prev" ] && [ "$(git -C "$r" rev-parse -q --verify "$prev^{tree}" 2>/dev/null)" = "$tree" ]; then echo "$n SNAPSHOT-UNCHANGED $wname"; continue; fi
    msg="snapshot of uncommitted work in $wt on $MACH at $TS (preserved by afx-preserve-all; working tree untouched)"
    commit=$(git -C "$wt" commit-tree "$tree" -p "$head" -m "$msg")
    afx_platform_timeout "$PUSH_TIMEOUT" git -C "$r" push -q origin "+$commit:$ref" 2>/dev/null && echo "$n SNAPSHOT $wname -> $ref" || echo "$n SNAPSHOT-PUSH-FAILED $wname"
  done
  # 4) expire this machine's snapshots that no longer describe anything
  afx_platform_timeout 60 git -C "$r" ls-remote origin "refs/afx/snapshot/$MACH/*" 2>/dev/null | while read -r sha ref; do
    [ -n "$ref" ] || continue; wname="${ref##*/}"; wtp=""
    wtp=$(git -C "$r" worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r w; do [ "$(basename "$w")" = "$wname" ] && [ -d "$w" ] && { echo "$w"; break; }; done)
    if [ -n "$wtp" ]; then
      [ -z "$(git -C "$wtp" status --porcelain 2>/dev/null)" ] || continue          # still dirty: the snapshot above is current
      why="the worktree is clean again"
    else
      when=$(git -C "$r" log -1 --format=%ct "$sha" 2>/dev/null) || when=""
      [ -n "$when" ] || continue                                                    # taken on another clone: not ours to judge
      [ $(( ($(date +%s) - when) / 86400 )) -ge "$KEEP_DAYS" ] || continue
      why="the worktree is gone and the snapshot is older than $KEEP_DAYS days"
    fi
    afx_platform_timeout 120 git -C "$r" push -q origin --delete "$ref" 2>/dev/null && echo "$n SNAPSHOT-EXPIRED $wname ($why)"
  done
done
