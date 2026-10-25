#!/bin/bash
# afx-sync-clones.sh: bring every registered canonical clone onto a current default branch, but ONLY when that cannot lose work.
#
#   scripts/afx-guard/afx-sync-clones.sh [--registry FILE | --clones-root DIR] [--only KEY] [--apply] [--no-fetch]
#   --clones-root DIR  for machines with no registry: every git repo directly under DIR is a clone (default branch from origin/HEAD, else main)
#
# Default is a dry run that says what it would do. With --apply it does exactly these two safe things and nothing else:
#   FAST-FORWARD   the clone is on the default branch with no modified tracked files and is behind origin: `merge --ff-only`.
#   SWITCH+FF      the clone is on another branch that is FULLY contained in origin/<default> (e.g. the retired `staging`),
#                  has no modified tracked files, and has no commits missing from GitHub: switch to the default, fast-forward.
# Everything else is only reported, never touched:
#   DIRTY            modified tracked files (someone's uncommitted work)
#   UNPUSHED-WORK    commits that exist on no remote branch: push or preserve them first
#   UNMERGED-PUSHED  branch has commits not in the default branch, but they are safe on GitHub: land them with afx-land.sh
#   DIVERGED         the local default branch cannot fast-forward
#   BLOCKED          the default branch is checked out in another worktree
# It never runs reset, clean, stash, checkout --, branch -D, or touches untracked files, stashes or other branches.
# Needs nothing but git and python (to read the registry). Portable to bash 3.2 / Git Bash.
set -u
_AFX_SC_DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
. "$_AFX_SC_DIR/afx-platform.sh"
REGISTRY="${AFX_REGISTRY:-}"; ONLY=""; APPLY=0; FETCH=1; CLONES_ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --registry) REGISTRY="$2"; shift 2;;
    --clones-root) CLONES_ROOT="$2"; shift 2;;
    --only) ONLY="$2"; shift 2;;
    --apply) APPLY=1; shift;;
    --no-fetch) FETCH=0; shift;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "afx-sync-clones: unknown argument $1" >&2; exit 64;;
  esac
done
PY=""; for c in python3 python; do if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import json' >/dev/null 2>&1; then PY="$c"; break; fi; done
[ -z "$PY" ] && { echo "afx-sync-clones: python is needed to read the registry" >&2; exit 2; }
if [ -z "$REGISTRY" ] && [ -z "$CLONES_ROOT" ]; then for c in "$HOME/Projects/afx-projects.json" "$HOME/Projects/allforx-projects.json" "/c/Users/${USER:-}/Projects/afx-projects.json" "/c/Users/${USER:-}/Projects/allforx-projects.json"; do [ -f "$c" ] && { REGISTRY="$c"; break; }; done; fi
[ -z "$REGISTRY" ] && [ -z "$CLONES_ROOT" ] && { echo "afx-sync-clones: no registry found (pass --registry FILE or --clones-root DIR)" >&2; exit 2; }
to_unix() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1" 2>/dev/null || echo "$1"; else echo "$1"; fi; }
LIST="$(mktemp)"; trap 'rm -f "$LIST"' EXIT
if [ -n "$CLONES_ROOT" ]; then
  for d in "$CLONES_ROOT"/*/; do
    [ -e "${d}.git" ] || continue
    d="${d%/}"; def=$(git -C "$d" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##'); [ -z "$def" ] && def=main
    printf '%s\t%s\t%s\n' "$(basename "$d")" "$d" "$def" >> "$LIST"
  done
else
"$PY" - "$REGISTRY" <<'PYEOF' > "$LIST"
import json, sys
sys.stdout.reconfigure(newline=chr(10))  # Windows Python would otherwise emit CRLF and bash would read a stray CR
d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
for p in d.get("projects", []):
    if p.get("paused"): continue
    print("\t".join([p.get("key", "") or "-", p.get("path") or "-", p.get("defaultBranch") or "main"]))
PYEOF
fi

line() { printf '%-28s %-16s %s\n' "$1" "$2" "$3"; }
n_ok=0; n_act=0; n_rep=0
while IFS="$(printf '\t')" read -r key path def; do
  [ -z "$key" ] || [ "$key" = "-" ] && continue
  [ "$path" = "-" ] && path=""
  [ -n "$ONLY" ] && [ "$ONLY" != "$key" ] && continue
  p="$(to_unix "$path")"
  git -C "$p" rev-parse --git-dir >/dev/null 2>&1 || { line "$key" "NOT-A-REPO" "$path"; n_rep=$((n_rep+1)); continue; }
  [ "$FETCH" = 1 ] && afx_platform_timeout 240 git -C "$p" fetch -q --prune origin 2>/dev/null
  git -C "$p" rev-parse --verify -q "origin/$def" >/dev/null || { line "$key" "NO-REMOTE-REF" "origin/$def missing"; n_rep=$((n_rep+1)); continue; }
  cur=$(git -C "$p" branch --show-current 2>/dev/null)
  dirty=$(git -C "$p" status --porcelain -uno 2>/dev/null | wc -l | tr -d ' ')
  behind=$(git -C "$p" rev-list --count "HEAD..origin/$def" 2>/dev/null)
  if [ "$dirty" != 0 ]; then
    top=$(git -C "$p" status --porcelain -uno 2>/dev/null | sed 's/^...//' | awk -F/ '{ if (NF > 1) print $1 "/" $2; else print $1 }' | sort | uniq -c | sort -nr | head -3 | awk '{printf "%s%s %s", (NR>1 ? ", " : ""), $2, $1}')
    line "$key" "DIRTY" "$dirty modified tracked file(s) on '${cur:-detached}' (top: $top); left alone"; n_rep=$((n_rep+1)); continue
  fi
  unpushed=$(git -C "$p" rev-list --count HEAD --not --remotes 2>/dev/null)
  if [ "${unpushed:-0}" != 0 ]; then line "$key" "UNPUSHED-WORK" "$unpushed commit(s) on '${cur:-detached}' exist on no remote branch; push or preserve them first"; n_rep=$((n_rep+1)); continue; fi
  if [ "$cur" = "$def" ]; then
    if [ "${behind:-0}" = 0 ]; then line "$key" "UP-TO-DATE" "$def @ $(git -C "$p" rev-parse --short HEAD)"; n_ok=$((n_ok+1)); continue; fi
    if ! git -C "$p" merge-base --is-ancestor HEAD "origin/$def"; then line "$key" "DIVERGED" "local $def has commits origin/$def lacks"; n_rep=$((n_rep+1)); continue; fi
    if [ "$APPLY" = 1 ] && git -C "$p" merge --ff-only -q "origin/$def" >/dev/null 2>&1; then line "$key" "FAST-FORWARD" "$def moved forward $behind commit(s)"; n_act=$((n_act+1))
    else line "$key" "WOULD-FF" "$def is $behind behind origin/$def"; n_act=$((n_act+1)); fi
    continue
  fi
  # on another branch
  if git -C "$p" merge-base --is-ancestor HEAD "origin/$def"; then
    if [ "$APPLY" = 1 ]; then
      if git -C "$p" show-ref --verify -q "refs/heads/$def"; then
        if ! git -C "$p" merge-base --is-ancestor "$def" "origin/$def"; then line "$key" "DIVERGED" "local $def has commits origin/$def lacks (still on '$cur')"; n_rep=$((n_rep+1)); continue; fi
        if git -C "$p" switch -q "$def" >/dev/null 2>&1 && git -C "$p" merge --ff-only -q "origin/$def" >/dev/null 2>&1; then line "$key" "SWITCH+FF" "'$cur' (fully merged) -> $def, fast-forwarded $behind commit(s)"; n_act=$((n_act+1))
        else line "$key" "BLOCKED" "could not switch to $def (checked out in another worktree?) from '$cur'"; n_rep=$((n_rep+1)); fi
      else
        if git -C "$p" switch -q -c "$def" --track "origin/$def" >/dev/null 2>&1; then line "$key" "SWITCH+FF" "'$cur' (fully merged) -> new local $def tracking origin/$def"; n_act=$((n_act+1))
        else line "$key" "BLOCKED" "could not create $def from origin/$def"; n_rep=$((n_rep+1)); fi
      fi
    else line "$key" "WOULD-SWITCH" "'$cur' is fully merged into origin/$def; would switch to $def and fast-forward ($behind behind)"; n_act=$((n_act+1)); fi
    continue
  fi
  ahead=$(git -C "$p" rev-list --count "origin/$def..HEAD" 2>/dev/null)
  line "$key" "UNMERGED-PUSHED" "'$cur' has $ahead commit(s) not in origin/$def (safe on GitHub); land them with afx-land.sh; $behind behind"
  n_rep=$((n_rep+1))
done < "$LIST"
echo
echo "afx-sync-clones: up-to-date $n_ok, $([ "$APPLY" = 1 ] && echo "acted on" || echo "would act on") $n_act, reported only $n_rep$([ "$APPLY" = 1 ] || echo ' (dry run: pass --apply)')"
exit 0
