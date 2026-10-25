#!/bin/bash
# afx-workspace-status.sh: is this checkout (or a Replit venture workspace) on current origin/main?  READ-ONLY by default.
#
#   afx-workspace-status.sh [<path>] [--json] [--no-fetch|--fetch] [--hook-line] [--ff]
#   afx-workspace-status.sh --venture <VENTURE> [--json]       Replit workspace, through afx-remote-ops.sh <V> status
#
# Owner rule 2026-10-15: pulling origin/main and staying on origin/main is a required process for every tool (Replit, Cursor,
# VS Code, Claude Code, ...). Code work happens ONLY in a worktree off origin/main; a main checkout stays a clean, current main.
#
# Output (one line, or JSON with --json): branch, kind (checkout|worktree), ahead/behind origin/main, dirty (tracked changes),
# untracked, verdict and the exact next step. Verdict tokens, joined with '+':
#   OK        clean main (checkout) or a wip worktree, nothing behind to worry about
#   BEHIND    main checkout is behind origin/main (a clean one is fast-forwarded by --ff)
#   DIRTY     tracked changes or untracked files in a main checkout (work belongs in a worktree)
#   DIVERGED  main checkout has local commits not on origin/main
#   OFFMAIN   main checkout is on another branch
#   WORKTREE_BEHIND  informational: a worktree branch is behind origin/main (afx-land merges it before gating)
#   UNREACHABLE      venture workspace could not be queried
# Exit: 0 verdict OK (or WORKTREE_BEHIND), 1 needs attention, 2 usage / not a git repo.
# --ff: the ONLY write: `git merge --ff-only origin/main` when the checkout is on main, has no tracked changes and nothing
#   ahead. Never resets, stashes, checks out, deletes or discards anything. A failing ff-only is reported, not forced.
# --hook-line: print nothing when OK; otherwise a single "afx-workspace: ..." line (used by the Claude/git/Cursor/VS Code hooks).
# Fetch: `git fetch origin main` into refs/remotes/origin/main only, at most once per AFX_WS_FETCH_TTL_S (default 300) per repo,
#   bounded by 20 s; if it fails the verdict uses the last known ref and says "stale".
# Venture mode never changes the workspace; Replit workspaces are aligned only through the rescue flow (afx-remote-ops.sh align-main).
set -u
_AFX_WS_DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
[ -f "$_AFX_WS_DIR/afx-platform.sh" ] && . "$_AFX_WS_DIR/afx-platform.sh"
type afx_platform_timeout >/dev/null 2>&1 || afx_platform_timeout() { shift; "$@"; }

TARGET=""; JSON=0; FETCH=auto; HOOK=0; FF=0; VENTURE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;; --no-fetch) FETCH=no ;; --fetch) FETCH=yes ;; --hook-line) HOOK=1 ;; --ff) FF=1 ;;
    --venture) shift; VENTURE="${1:-}" ;;
    -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]:-$0}" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "afx-workspace-status: unknown option $1" >&2; exit 2 ;;
    *) TARGET="$1" ;;
  esac; shift
done

jstr() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r'; }
emit_json() { # repo path kind branch head ahead behind dirty untracked verdict action fetched
  local okv=false
  if [ "${10}" = OK ] || [ "${10}" = WORKTREE_BEHIND ]; then okv=true; fi
  printf '{"repo":"%s","path":"%s","kind":"%s","branch":"%s","head":"%s","ahead":%s,"behind":%s,"dirty":%s,"untracked":%s,"verdict":"%s","ok":%s,"action":"%s","fetched":"%s"}\n' \
    "$(jstr "$1")" "$(jstr "$2")" "$3" "$(jstr "$4")" "$5" "$6" "$7" "$8" "$9" "${10}" "$okv" "$(jstr "${11}")" "${12}"
}

# ---------------------------------------------------------------- venture mode
if [ -n "$VENTURE" ]; then
  OPS="${AFX_OPS_SCRIPT:-$_AFX_WS_DIR/afx-remote-ops.sh}"
  out="$(bash "$OPS" "$VENTURE" status 2>&1)"; rc=$?
  line="$(printf '%s\n' "$out" | grep -E '^(afx-remote-ops: )?SYNC: ' | tail -1 | sed 's/^afx-remote-ops: //')"
  if [ -z "$line" ]; then
    verdict=UNREACHABLE; branch=""; ahead=0; behind=0; dirty=0; untracked=0
    action="could not read the workspace state (afx-remote-ops.sh $VENTURE status exit $rc); try it by hand, do not guess"
  else
    verdict="$(printf '%s' "$line" | sed -n 's/^SYNC: *\([A-Z_+]*\).*/\1/p')"
    getv() { printf '%s' "$line" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
    branch="$(getv branch)"; ahead="$(getv ahead)"; behind="$(getv behind)"; dirty="$(getv dirty)"; untracked="$(getv untracked)"
    : "${ahead:=0}" "${behind:=0}" "${dirty:=0}" "${untracked:=0}"
    case "$verdict" in
      OK) action="none" ;;
      *) action="report only: align the Replit workspace through the rescue flow (afx-remote-ops.sh $VENTURE align-main --dry-run), never by hand" ;;
    esac
  fi
  if [ "$JSON" = 1 ]; then emit_json "$VENTURE" "replit:$VENTURE" replit "$branch" "" "$ahead" "$behind" "$dirty" "$untracked" "$verdict" "$action" "n/a"
  else printf 'afx-workspace: %s (Replit) %s branch=%s ahead=%s behind=%s dirty=%s untracked=%s%s\n' "$VENTURE" "$verdict" "${branch:-?}" "$ahead" "$behind" "$dirty" "$untracked" "$([ "$verdict" = OK ] && echo '' || echo " -> $action")"; fi
  [ "$verdict" = OK ] && exit 0 || exit 1
fi

# ---------------------------------------------------------------- local mode
[ -n "$TARGET" ] || TARGET="$PWD"
[ -d "$TARGET" ] || TARGET="$(dirname "$TARGET")"
top="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null)" || top=""
if [ -z "$top" ]; then
  [ "$JSON" = 1 ] && emit_json "" "$TARGET" none "" "" 0 0 0 0 NOT_A_REPO "not inside a git repository" no
  [ "$HOOK" = 1 ] || { [ "$JSON" = 1 ] || echo "afx-workspace: $TARGET is not inside a git repository"; }
  exit 2
fi
repo="$(basename "$top")"
gitdir="$(git -C "$top" rev-parse --absolute-git-dir 2>/dev/null)"
common="$(git -C "$top" rev-parse --git-common-dir 2>/dev/null)"
case "$common" in /*) ;; *) common="$top/$common" ;; esac
common="${common%/.}"
[ "$gitdir" = "$common" ] && kind=checkout || kind=worktree
if [ "$kind" = worktree ]; then repo="$(basename "$(dirname "$common")")"; fi
branch="$(git -C "$top" rev-parse --abbrev-ref HEAD 2>/dev/null)"; head="$(git -C "$top" rev-parse --short HEAD 2>/dev/null)"

fetched=no
if [ "$FETCH" != no ] && git -C "$top" remote get-url origin >/dev/null 2>&1; then
  stamp="$common/afx-ws-fetch-stamp"; now=$(date +%s); ttl="${AFX_WS_FETCH_TTL_S:-300}"; last=0
  [ -f "$stamp" ] && last="$(cat "$stamp" 2>/dev/null || echo 0)"; case "$last" in ''|*[!0-9]*) last=0;; esac
  if [ "$FETCH" = yes ] || [ $((now - last)) -ge "$ttl" ]; then
    if afx_platform_timeout 20 git -C "$top" fetch -q origin "+refs/heads/main:refs/remotes/origin/main" >/dev/null 2>&1; then
      fetched=yes; echo "$now" > "$stamp" 2>/dev/null
    else fetched=failed; fi
  else fetched=cached; fi
fi
basebr="origin/main"
git -C "$top" rev-parse --verify -q "origin/main^{commit}" >/dev/null 2>&1 || {
  if git -C "$top" rev-parse --verify -q "origin/master^{commit}" >/dev/null 2>&1; then basebr="origin/master"; else basebr=""; fi; }
ahead=0; behind=0
if [ -n "$basebr" ]; then
  lr="$(git -C "$top" rev-list --left-right --count "HEAD...$basebr" 2>/dev/null)" && { ahead="$(printf '%s' "$lr" | awk '{print $1}')"; behind="$(printf '%s' "$lr" | awk '{print $2}')"; }
fi
dirty="$(git -C "$top" status --porcelain -uno 2>/dev/null | wc -l | tr -d ' ')"
untracked="$(git -C "$top" status --porcelain 2>/dev/null | grep -c '^??')"; untracked="${untracked:-0}"

verdict=""; action="none"; v() { verdict="${verdict:+$verdict+}$1"; }
mainname="${basebr#origin/}"
if [ "$kind" = checkout ]; then
  [ "$branch" != "$mainname" ] && v OFFMAIN
  [ "$behind" -gt 0 ] && [ "$branch" = "$mainname" ] && v BEHIND
  [ "$ahead" -gt 0 ] && [ "$branch" = "$mainname" ] && v DIVERGED
  { [ "$dirty" -gt 0 ] || [ "$untracked" -gt 0 ]; } && v DIRTY
  # a wip branch parked in a main checkout, clean and not behind, is tolerated
  case "$branch" in wip/*) [ "$verdict" = OFFMAIN ] && [ "$behind" = 0 ] && [ "$dirty" = 0 ] && [ "$untracked" = 0 ] && verdict="" ;; esac
  # fast-forward: clean main, behind, nothing ahead, no tracked changes
  if [ "$FF" = 1 ] && [ "$branch" = "$mainname" ] && [ "$behind" -gt 0 ] && [ "$ahead" = 0 ] && [ "$dirty" = 0 ]; then
    if git -C "$top" merge --ff-only -q "$basebr" >/dev/null 2>&1; then
      head="$(git -C "$top" rev-parse --short HEAD)"; behind=0
      verdict="$(printf '%s' "$verdict" | sed 's/BEHIND+\{0,1\}//; s/+$//')"
      ffnote="fast-forwarded $mainname to $basebr ($head)"
    else ffnote="fast-forward to $basebr FAILED (left untouched): run afx-sync-clones.sh"; fi
  fi
else
  [ "$behind" -gt 0 ] && v WORKTREE_BEHIND
fi
[ -z "$verdict" ] && verdict=OK
case "$verdict" in
  OK) action="none" ;;
  WORKTREE_BEHIND) action="behind origin/main by $behind: afx-land.sh merges main before gating; or git merge origin/main in this worktree" ;;
  *DIVERGED*) action="this main checkout has $ahead local commit(s) not on origin/main: never commit on main. Keep them on a worktree branch (afx-ai start $repo <topic>, cherry-pick), then run afx-sync-clones.sh" ;;
  *DIRTY*) action="main checkout has $dirty changed and $untracked untracked path(s): do not work here. Work only in a worktree (afx-ai start $repo <topic>); then afx-sync-clones.sh" ;;
  *OFFMAIN*) action="main checkout is on '$branch': a main checkout stays on main. Work only in a worktree (afx-ai start $repo <topic>); then run afx-sync-clones.sh" ;;
  *BEHIND*) action="main is $behind behind $basebr: run afx-sync-clones.sh (or afx-workspace-status.sh --ff), and work only in a worktree" ;;
esac
[ "$fetched" = failed ] && action="$action (fetch failed: ref may be stale)"
ffnote="${ffnote:-}"

if [ "$JSON" = 1 ]; then
  emit_json "$repo" "$top" "$kind" "$branch" "$head" "$ahead" "$behind" "$dirty" "$untracked" "$verdict" "${ffnote:+$ffnote; }$action" "$fetched"
elif [ "$HOOK" = 1 ]; then
  if [ -n "$ffnote" ]; then echo "afx-workspace: $repo $ffnote"; fi
  case "$verdict" in
    OK) ;;
    WORKTREE_BEHIND) [ "${AFX_WS_SESSION:-0}" = 1 ] && echo "afx-workspace: $repo $verdict on '$branch' (behind=$behind): $action" ;;
    *) echo "afx-workspace: $repo $verdict on '$branch' (ahead=$ahead behind=$behind dirty=$dirty untracked=$untracked): $action" ;;
  esac
else
  echo "afx-workspace: $repo ($kind) $verdict branch=$branch head=$head ahead=$ahead behind=$behind dirty=$dirty untracked=$untracked fetch=$fetched${ffnote:+ | $ffnote}$([ "$action" = none ] && echo '' || echo " -> $action")"
fi
case "$verdict" in OK|WORKTREE_BEHIND) exit 0 ;; *) exit 1 ;; esac
