#!/bin/bash
# afx-terminal-agent-launcher.sh: the Mac/Linux counterpart to windows/afx-terminal-agent-launcher.ps1
# (renamed 2026-10-14 from afx-open.sh / Open-AllForX.ps1; the old names remain as forwarding shims).
#
# Sessions START IN THE MACHINE'S HOME FOLDER ($HOME, override AFX_LAUNCH_DIR), not in a clone, so a terminal
# can do broader work (owner decision 2026-10-14). The focus project is read with git -C and named to the agent
# via --append-system-prompt. --at-project starts inside the clone instead (only when necessary or asked).
# `root` opens a session with no focus project. Works unchanged on cloud shells / VMs: home is $HOME there.
# Same
# allforx-projects.json schema (see allforx-projects.example.json), same
# checks, so every machine starts a session the same way: verify the
# canonical clone is really that project's repo, fetch (never pull), and
# print unpushed/uncommitted/stash/worktree/ahead-behind status BEFORE any
# work starts.
#
#   scripts/afx-guard/afx-terminal-agent-launcher.sh -List
#   scripts/afx-guard/afx-terminal-agent-launcher.sh <key>
#   scripts/afx-guard/afx-terminal-agent-launcher.sh htr --no-fetch
#   scripts/afx-guard/afx-terminal-agent-launcher.sh hub --no-claude     # status only, don't launch
#
# Config resolution order: $AFX_PROJECTS_JSON, then allforx-projects.json next
# to this script, then ~/allforx-projects.json. None of these are committed
# (see allforx-projects.example.json for the schema and why).
#
# Window behavior differs by platform on purpose, matching what each platform
# actually has:
#   - macOS, no --here: opens a new Terminal.app window at the project path
#     (osascript) and starts claude there, mirroring the Windows launcher's
#     "one window per project". Falls back to --here behavior if osascript
#     or a GUI session isn't available (e.g. over a headless SSH login).
#   - Linux (Replit repls): always --here. There is no desktop session to open
#     a new window in; the "session" is the SSH/terminal connection itself.
#   - Windows: not this script — use windows/afx-terminal-agent-launcher.ps1.
set -u
DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "$0")" && pwd)}"
. "$DIR/afx-platform.sh"

HERE=0; NO_FETCH=0; NO_CLAUDE=0; LIST=0; PROJECT=""; MODEL=""; AT_PROJECT=0
START_DIR="${AFX_LAUNCH_DIR:-$HOME}"
for a in "$@"; do
  case "$a" in
    -List|--list) LIST=1 ;;
    --here) HERE=1 ;;
    --at-project|-AtProject) AT_PROJECT=1 ;;
    --no-fetch) NO_FETCH=1 ;;
    --no-claude) NO_CLAUDE=1 ;;
    --model=*) MODEL="${a#--model=}" ;;
    -*) ;;
    *) [ -z "$PROJECT" ] && PROJECT="$a" ;;
  esac
done

CONFIG="${AFX_PROJECTS_JSON:-}"
[ -z "$CONFIG" ] && [ -f "$DIR/allforx-projects.json" ] && CONFIG="$DIR/allforx-projects.json"
[ -z "$CONFIG" ] && [ -f "$HOME/allforx-projects.json" ] && CONFIG="$HOME/allforx-projects.json"
if [ -z "$CONFIG" ] || [ ! -f "$CONFIG" ]; then
  echo "Missing allforx-projects.json (checked \$AFX_PROJECTS_JSON, $DIR/allforx-projects.json, $HOME/allforx-projects.json)." >&2
  echo "Copy $DIR/allforx-projects.example.json to one of those paths and fill in this machine's real paths." >&2
  exit 2
fi

_py() { python3 - "$CONFIG" "$@"; }

if [ "$LIST" = 1 ] || [ -z "$PROJECT" ]; then
  _py <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
for p in cfg.get("projects", []):
    target = p.get("stagingBranch") or p.get("defaultBranch", "main")
    state = "paused" if p.get("paused") else ("see notes" if p.get("notes") else "ok")
    print(f"{p['key']:12} {p['name']:28} target={target:10} state={state:10} {p['path']}")
notes = [p for p in cfg.get("projects", []) if p.get("notes")]
for p in notes:
    print(f"  note: {p['key']}: {p['notes']}")
PY
  exit 0
fi

if [ "$PROJECT" = "root" ]; then
  [ "$NO_CLAUDE" = 1 ] && { echo "Root session folder: $START_DIR"; exit 0; }
  command -v claude >/dev/null 2>&1 || { echo "claude is not on PATH." >&2; exit 3; }
  cd "$START_DIR" || exit 1
  if [ "$HERE" != 1 ] && [ "$(afx_platform_os)" = mac ] && command -v osascript >/dev/null 2>&1; then
    osascript -e "tell application \"Terminal\" to do script \"cd \\\"$START_DIR\\\" && claude\"" >/dev/null 2>&1 && { echo "Opened a root Terminal window in $START_DIR"; exit 0; }
  fi
  if [ -n "$MODEL" ]; then exec claude --model "$MODEL"; else exec claude; fi
fi
RESOLVED=$(_py "$PROJECT" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
name = sys.argv[2].lower()
for p in cfg.get("projects", []):
    aliases = [a.lower() for a in p.get("aliases", [])]
    if p["key"].lower() == name or name in aliases or p["name"].lower() == name:
        print(json.dumps(p)); sys.exit(0)
sys.exit(1)
PY
) || { echo "Unknown project '$PROJECT'. Run 'afx-terminal-agent-launcher.sh -List' for valid keys." >&2; exit 2; }

PPATH=$(echo "$RESOLVED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])')
PREPO=$(echo "$RESOLVED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["repo"])')
PNAME=$(echo "$RESOLVED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
PPAUSED=$(echo "$RESOLVED" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("paused", False))')
PNOTES=$(echo "$RESOLVED" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("notes",""))')
PTARGET=$(echo "$RESOLVED" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("stagingBranch") or d.get("defaultBranch","main"))')

[ -d "$PPATH/.git" ] || { echo "Canonical clone for $PNAME is missing or not a git repo: $PPATH" >&2; echo "Do NOT clone it somewhere else. Fix the path in $CONFIG or ask the owner." >&2; exit 2; }
ORIGIN=$(git -C "$PPATH" config --get remote.origin.url 2>/dev/null)
[ -n "$ORIGIN" ] || { echo "$PPATH has no 'origin' remote. A repo with no remote is a bug — stop and tell the owner." >&2; exit 2; }
SLUG=$(echo "$ORIGIN" | sed -E 's#\.git$##; s#^.*github\.com[:/]##' | tr '[:upper:]' '[:lower:]')
[ "$SLUG" = "$(echo "$PREPO" | tr '[:upper:]' '[:lower:]')" ] || { echo "Wrong repo in the canonical folder for $PNAME: origin is '$ORIGIN' but expected github.com/$PREPO." >&2; exit 2; }

echo ""
echo "=== $PNAME ==="
echo "Session: $([ "$AT_PROJECT" = 1 ] && echo "$PPATH" || echo "$START_DIR   (home folder; project work happens in the clone below via a worktree)")"
echo "Folder : $PPATH"
echo "GitHub : $PREPO   work targets: $PTARGET   (main changes only via afx-land.sh from a wip/ worktree)"
[ "$PPAUSED" = "True" ] && echo "PAUSED : the owner has paused this project. Do not start new work without their say-so."
[ -n "$PNOTES" ] && echo "NOTE   : $PNOTES"

if [ "$NO_FETCH" != 1 ]; then
  echo "Fetching (remote refs only — nothing is pulled or merged)..."
  afx_platform_timeout 120 git -C "$PPATH" fetch -q origin 2>&1 | sed 's/^/  /' || echo "  fetch failed — status below may be stale"
fi

BRANCH=$(git -C "$PPATH" rev-parse --abbrev-ref HEAD 2>/dev/null)
MODIFIED=$(git -C "$PPATH" status --porcelain -uno 2>/dev/null | wc -l | tr -d ' ')
UNTRACKED=$(git -C "$PPATH" status --porcelain 2>/dev/null | grep -c '^??')
UNPUSHED=$(git -C "$PPATH" log --branches --not --remotes --oneline 2>/dev/null | wc -l | tr -d ' ')
STASHES=$(git -C "$PPATH" stash list 2>/dev/null | wc -l | tr -d ' ')
WORKTREES=$(( $(git -C "$PPATH" worktree list 2>/dev/null | wc -l | tr -d ' ') - 1 ))
AHEAD=0; BEHIND=0
if git -C "$PPATH" rev-parse --verify --quiet "refs/remotes/origin/$PTARGET" >/dev/null 2>&1; then
  BEHIND=$(git -C "$PPATH" rev-list --count "HEAD..origin/$PTARGET" 2>/dev/null)
  AHEAD=$(git -C "$PPATH" rev-list --count "origin/$PTARGET..HEAD" 2>/dev/null)
  echo "Branch : $BRANCH   vs origin/$PTARGET: $AHEAD ahead, $BEHIND behind"
else
  echo "Branch : $BRANCH   (origin/$PTARGET not known locally yet — rerun without --no-fetch)"
fi
echo "Local  : $MODIFIED modified, $UNTRACKED untracked, $STASHES stash(es), $WORKTREES extra worktree(s)"
[ "${UNPUSHED:-0}" -gt 0 ] 2>/dev/null && echo "UNPUSHED: $UNPUSHED commit(s) exist on no remote. Push them to a branch before doing anything else."
[ "${MODIFIED:-0}" -gt 0 ] 2>/dev/null && echo "UNCOMMITTED: $MODIFIED modified file(s). If they are not yours, leave them alone and tell the owner. Never restore, reset, clean or stash them away."
[ "${BEHIND:-0}" -gt 0 ] 2>/dev/null && echo "BEHIND: do not pull blindly. Look at 'git log HEAD..origin/$PTARGET --stat' first; with local changes present, ask the owner."
echo ""

[ "$NO_CLAUDE" = 1 ] && exit 0
command -v claude >/dev/null 2>&1 || { echo "claude is not on PATH." >&2; exit 3; }

CLAUDE_ARGS=(); [ -n "$MODEL" ] && CLAUDE_ARGS+=(--model "$MODEL")
LAUNCH_DIR="$START_DIR"; [ "$AT_PROJECT" = 1 ] && LAUNCH_DIR="$PPATH"
if [ "$AT_PROJECT" != 1 ]; then
  CTX="Session started at the home folder $START_DIR by owner decision (2026-10-14), not inside a clone. Focus project: $PNAME, canonical clone $PPATH, repo $PREPO, work branches target origin/$PTARGET. Do project work in a worktree under $PPATH/.claude/worktrees/<name>; never git init or clone a project; never touch uncommitted changes you did not make. Land with afx-land.sh (AFX_GUARD_DIR) from a wip/ worktree."
  CLAUDE_ARGS+=(--append-system-prompt "$CTX")
fi

if [ "$HERE" = 1 ] || [ "$(afx_platform_os)" != mac ] || ! command -v osascript >/dev/null 2>&1; then
  cd "$LAUNCH_DIR" || exit 1
  exec claude "${CLAUDE_ARGS[@]}"
fi

# macOS Terminal window. Quote each arg for the shell string handed to Terminal.
QARGS=""; for a in "${CLAUDE_ARGS[@]}"; do QARGS="$QARGS $(printf '%q' "$a")"; done
ESCAPED_DIR=$(printf '%s' "$LAUNCH_DIR" | sed 's/"/\\"/g')
ESCAPED_CMD=$(printf '%s' "claude$QARGS" | sed 's/\\/\\\\/g; s/"/\\"/g')
osascript -e "tell application \"Terminal\" to do script \"cd \\\"$ESCAPED_DIR\\\" && $ESCAPED_CMD\"" >/dev/null 2>&1 \
  && { echo "Opened a Terminal window for $PNAME in $LAUNCH_DIR"; exit 0; } \
  || echo "Could not open a new Terminal window (no GUI session?); falling back to --here."
cd "$LAUNCH_DIR" || exit 1
exec claude "${CLAUDE_ARGS[@]}"