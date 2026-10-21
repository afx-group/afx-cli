#!/bin/bash
# afx-where-am-i.sh: is this an approved place for an agent to work? (R20 working locations)
#
#   scripts/afx-guard/afx-where-am-i.sh [path]      classify a path (default: $PWD)
#   scripts/afx-guard/afx-where-am-i.sh --hook      Claude Code PreToolUse/SessionStart hook:
#                                                   reads the hook JSON on stdin, blocks writes
#                                                   outside the allowlist (exit 2, reason on stderr)
#
# Classes (printed as "<CLASS> <path> — <why>"):
#   WORKTREE   <clones>/<repo>/.claude/worktrees/<name>         code work goes here          exit 0
#   CHECKOUT   <clones>/<repo> main checkout                    read/fetch only, never edit  exit 3
#   DEPLOY     Replit ~/workspace                               deploy target, never edit    exit 3
#   GATE       Replit ~/gate-* or ~/e2e-* disposable clones     gates/E2E only               exit 0
#   SCRATCH    Claude session scratchpad                        logs/previews, never code    exit 0
#   DOCS       AllForX/_readiness, HUMAN_ACTIONS.md, ~/.claude  coordination docs/memory     exit 0
#   HOME       $HOME itself                                     launch/coordinate, no files  exit 3
#   BLOCKED    anything else (/tmp, Desktop, other Downloads folders, stray clones, …)     exit 2
#
# Uncommitted-work age tiers (owner, 2026-09-27: "every 2-4-8 hours"), checked at
# session start and on manual runs only, never per edit, so it adds no per-write cost:
#   >= 2h NOTICE    commit + push a WIP commit to your branch
#   >= 4h WARN      same, louder; the fragment audit lists it for the coordinator
#   >= 8h PRESERVE  snapshot via afx-preserve-all.sh to archive/<machine>/* (the
#                   worktree itself is never touched) and it is escalated
# Override with AFX_STALE_TIERS="2 4 8".
# Policy: docs/AFX_WORKING_LOCATIONS.md. Portable: macOS, Linux (Replit), Git Bash.
set -u
_AFX_W_DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
. "$_AFX_W_DIR/afx-platform.sh"

OS=$(afx_platform_os)
read -r T1 T2 T3 <<< "${AFX_STALE_TIERS:-2 4 8}"
CHECK_STALE=1

clones_root() {
  if [ -n "${AFX_CLONES_ROOT:-}" ]; then echo "$AFX_CLONES_ROOT"; return; fi
  # machine.conf `root=` is the single per-machine destination (set by afx-new-mac-setup.sh).
  local mc; mc=$(sed -n 's/^root=//p' "$HOME/.claude/hooks/afx-guard/machine.conf" 2>/dev/null | head -1)
  if [ -n "$mc" ]; then echo "${mc/#\~/$HOME}"; return; fi
  local _c   # config keys clonesRootMac / clonesRootWindows (defaults: the AFX layout; allforx-projects.json "root" on Windows)
  case "$OS" in
    mac) _c=$(afx_config_get clonesRootMac); echo "${_c/#\~/$HOME}" ;;
    windows) _c=$(afx_config_get clonesRootWindows); echo "${_c/#\~/$HOME}" ;;
    *) echo "" ;;                                # Replit repls have no clones root
  esac
}

abspath() {
  local p="$1"
  if [ -d "$p" ]; then (cd "$p" 2>/dev/null && pwd -P) && return; fi
  local d; d=$(dirname "$p")
  while [ ! -d "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do d=$(dirname "$d"); done
  local rest="${p#"$d"}"
  echo "$( (cd "$d" 2>/dev/null && pwd -P) )$rest"
}

stale_check() {
  [ "$CHECK_STALE" = 1 ] || return 0
  local wt="$1" now oldest=0 f m h
  now=$(date +%s)
  while IFS= read -r f; do
    [ -e "$wt/$f" ] || continue
    m=$(afx_platform_stat_mtime "$wt/$f" 2>/dev/null) || continue
    { [ "$oldest" = 0 ] || [ "$m" -lt "$oldest" ]; } && oldest=$m
  done < <(git -C "$wt" status --porcelain 2>/dev/null | sed 's/^...//; s/.* -> //' | head -200)
  [ "$oldest" = 0 ] && return 0
  h=$(( (now - oldest) / 3600 ))
  if [ "$h" -ge "$T3" ]; then
    echo "PRESERVE uncommitted work in $wt is ${h}h old (>= ${T3}h): commit and push now, or run afx-preserve-all.sh to snapshot it to archive/*; escalate to the coordinator" >&2
  elif [ "$h" -ge "$T2" ]; then
    echo "WARN uncommitted work in $wt is ${h}h old (>= ${T2}h): commit and push a WIP commit to your branch" >&2
  elif [ "$h" -ge "$T1" ]; then
    echo "NOTICE uncommitted work in $wt is ${h}h old (>= ${T1}h): commit and push when you reach a stable point" >&2
  fi
}

# classify <abs path>  → prints line, returns class exit code
classify() {
  local p="$1" root; root=$(clones_root)
  [ -n "$root" ] && root=$(abspath "$root")
  local scratch_re="^(/private)?/tmp/claude-[0-9]+/|^${TMPDIR:-/nonexistent}claude-|^/tmp/claude/|/[Tt]emp/claude/"

  if [ -n "$root" ] && case "$p/" in "$root"/*) true ;; *) false ;; esac; then
    local rel="${p#"$root"/}"
    case "$rel" in
      */.claude/worktrees/*)
        local wt="$root/${rel%%/.claude/worktrees/*}/.claude/worktrees/$(echo "${rel#*/.claude/worktrees/}" | cut -d/ -f1)"
        echo "WORKTREE $p — code work belongs here"; stale_check "$wt"; return 0 ;;
      */.claude/scratch|*/.claude/scratch/*)
        echo "SCRATCH $p — repo-local scratch; never the only copy of work"; return 0 ;;
    esac
    local top; top=$(git -C "$( [ -d "$p" ] && echo "$p" || dirname "$p")" rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$top" ]; then
      echo "CHECKOUT $p — main checkout of $(basename "$top"): read/fetch only; edit in $top/.claude/worktrees/<name>"; return 3
    fi
    echo "CHECKOUT $p — inside the clones root but not in a repo; don't create files here"; return 3
  fi

  if [ "$OS" = linux ]; then
    case "$p/" in
      "$HOME/workspace/"*) echo "DEPLOY $p — Replit ~/workspace is the deploy target: never create or edit files here"; return 3 ;;
      "$HOME"/gate-*|"$HOME"/e2e-*) echo "GATE $p — disposable gate/E2E clone; delete after the run"; return 0 ;;
    esac
  fi

  if echo "$p/" | grep -Eq "$scratch_re"; then
    echo "SCRATCH $p — session scratchpad: logs/previews only, never the only copy of code"; return 0
  fi

  local _mr _afxbase; _mr=$(afx_config_get clonesRootMac); _afxbase=$(dirname "${_mr/#\~/$HOME}")   # the folder holding the clones root
  case "$p/" in
    "$_afxbase/_readiness/"*|"$_afxbase/HUMAN_ACTIONS.md/"|"$HOME/.claude/"*|"$HOME/.ssh/"*)
      echo "DOCS $p — coordination docs / agent memory"; return 0 ;;
  esac

  if [ "$p" = "$HOME" ] || [ "$p" = "$(abspath "$HOME")" ]; then
    echo "HOME $p — launch/coordination only: switch to a worktree before editing"; return 3
  fi

  echo "BLOCKED $p — not an approved AFX working location (see docs/AFX_WORKING_LOCATIONS.md)"
  return 2
}

json_field() { # json_field <name> : first string value of "name" in stdin JSON (no jq dependency)
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# Hook JSON on Windows carries JSON-escaped Windows paths ("C:\\Users\\x\\y"). json_field above returns them still escaped, so
# without this every path looked like one odd file name and nothing matched /.claude/worktrees/. Normalise to the POSIX form
# Git Bash uses (C:\Users\x -> /c/Users/x). POSIX paths pass through unchanged.
norm_hook_path() {
  local p="$1"
  p="${p//\\\\//}"   # JSON-escaped backslash pairs
  p="${p//\\//}"       # remaining backslashes
  if [[ "$p" =~ ^([A-Za-z]):/(.*)$ ]]; then
    # cygpath uses the same mount table as `pwd -P` (e.g. %TEMP% is /tmp in Git Bash), so classify() compares like with like.
    if command -v cygpath >/dev/null 2>&1; then
      p=$(cygpath -u "$p" 2>/dev/null || printf '%s' "$p")
    else
      local d; d=$(printf '%s' "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')
      p="/$d/${BASH_REMATCH[2]}"
    fi
  fi
  printf '%s' "$p"
}

# ws_status <dir> <session 1|0>: one advisory line from afx-workspace-status.sh (fetch is rate limited there). Fail-open: never blocks.
ws_status() {
  local ws="$_AFX_W_DIR/afx-workspace-status.sh"
  [ -f "$ws" ] || return 0
  AFX_WS_SESSION="$2" bash "$ws" "$1" --hook-line --ff 2>/dev/null || true
}

if [ "${1:-}" = "--hook" ]; then
  input=$(cat)
  event=$(printf '%s' "$input" | json_field hook_event_name)
  tool=$(printf '%s' "$input" | json_field tool_name)
  cwd=$(norm_hook_path "$(printf '%s' "$input" | json_field cwd)")
  target=$(norm_hook_path "$(printf '%s' "$input" | json_field file_path)")
  [ -z "$target" ] && target=$(norm_hook_path "$(printf '%s' "$input" | json_field notebook_path)")
  [ -z "$target" ] && target="${cwd:-$PWD}"
  if [ "$event" = SessionStart ]; then
    # Never block a session from starting; tell the agent where it is (+ stale-work tiers).
    line=$(classify "$(abspath "$target")" 2>&1)
    echo "afx-where-am-i: $line"
    # always on origin/main (owner rule 2026-10-15): fetch, fast-forward a clean main that is behind, say what to do otherwise. Never destructive.
    ws_status "${cwd:-$PWD}" 1
    # red mains (afx-main-health.sh writes <alerts>/<repo>-<sha>.txt, a green run removes them): shown at every session start
    for al in "${AFX_ALERT_DIR:-$HOME/.afx/alerts}"/*.txt; do
      [ -f "$al" ] || continue
      echo "afx-where-am-i: RED MAIN $(head -1 "$al"). Only its fix lands (afx-land.sh --fixes-main). Details: $al"
    done
    exit 0
  fi
  if [ "$event" = UserPromptSubmit ]; then ws_status "${cwd:-$PWD}" 0; exit 0; fi
  CHECK_STALE=0   # per-edit checks stay a cheap path match
  line=$(classify "$(abspath "$target")"); rc=$?
  case "$tool" in
    Write|Edit|MultiEdit|NotebookEdit)
      if [ $rc = 2 ] || [ $rc = 3 ]; then echo "afx-where-am-i blocked $tool: $line" >&2; exit 2; fi ;;
    # Bash is not gated: commands legitimately read anywhere and sessions often
    # start in ~. File writes are what create fragments, so Write/Edit are gated,
    # and afx-fragment-audit.sh sweeps for anything a shell command left behind.
  esac
  exit 0
fi

classify "$(abspath "${1:-$PWD}")"
