#!/bin/bash
# afx-skill-render.sh: keep the repo copies of the AFX agent skills identical, from ONE source each.
#
#   afx-skill-render.sh [--write] <repo-path>     copy the canonical skill files over the other copies (default mode)
#   afx-skill-render.sh --check <repo-path>       read-only; exit 1 if any copy is missing, stale or has an extra file
#   afx-skill-render.sh --list                    print "skill: source -> target" lines
#
# Pattern follows afx-agent-rules-sync.sh (--write/--check/--list, exit 0 ok / 1 drift / 2 usage, bash 3.2 + BSD userland).
# Canonical source for every skill: .claude/skills/<skill>/ (Claude Code reads it; it is the maintained copy).
#   afx-ai-toolkit -> .cursor/skills/afx-ai-toolkit, .agents/skills/afx-ai-toolkit
#   afx-playbook   -> no other repo copy (the user-level ~/.claude/skills copy is outside the repo: reported, never changed)
# Edit only the canonical copy, then run --write and commit. Never deletes and never runs git: a file that exists in a
# target but not in the source is reported as EXTRA (remove it by hand with git rm) and counts as drift.
# The user-level copy diff is informational only and never affects the exit code (AFX_SKILL_USER_DIR overrides ~/.claude/skills).
set -u
SRC_ROOT=".claude/skills"
SKILLS="afx-ai-toolkit afx-playbook"
targets_for() { case "$1" in afx-ai-toolkit) echo ".cursor/skills .agents/skills" ;; *) echo "" ;; esac; }

MODE=write; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check ;; --write) MODE=write ;;
    --list)
      for s in $SKILLS; do
        t="$(targets_for "$s")"
        if [ -z "$t" ]; then echo "$s: $SRC_ROOT/$s (no other repo copy)"; continue; fi
        for r in $t; do echo "$s: $SRC_ROOT/$s -> $r/$s"; done
      done; exit 0 ;;
    -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]:-$0}" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "afx-skill-render: unknown option $1" >&2; exit 2 ;;
    *) REPO="$1" ;;
  esac; shift
done
[ -n "$REPO" ] || { echo "afx-skill-render: repo path required" >&2; exit 2; }
[ -d "$REPO" ] || { echo "afx-skill-render: not a directory: $REPO" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd -P)"
USER_DIR="${AFX_SKILL_USER_DIR:-$HOME/.claude/skills}"

DRIFT=0; N=0
for s in $SKILLS; do
  src="$REPO/$SRC_ROOT/$s"
  [ -d "$src" ] || { echo "afx-skill-render: canonical source missing: $SRC_ROOT/$s" >&2; exit 2; }
  files="$(cd "$src" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)"
  for r in $(targets_for "$s"); do
    dst="$REPO/$r/$s"
    for f in $files; do
      N=$((N+1)); rel="$r/$s/$f"
      if [ -f "$dst/$f" ] && cmp -s "$src/$f" "$dst/$f"; then echo "OK    $rel"; continue; fi
      if [ -f "$dst/$f" ]; then st=stale; else st=missing; fi
      if [ "$MODE" = check ]; then echo "DRIFT $rel ($st)"; DRIFT=$((DRIFT+1)); continue; fi
      mkdir -p "$(dirname "$dst/$f")" && cp "$src/$f" "$dst/$f" && echo "WROTE $rel ($st -> synced)"
    done
    if [ -d "$dst" ]; then
      for f in $(cd "$dst" && find . -type f | sed 's|^\./||' | LC_ALL=C sort); do
        [ -f "$src/$f" ] || { echo "EXTRA $r/$s/$f (not in the canonical copy; git rm it)"; DRIFT=$((DRIFT+1)); }
      done
    fi
  done
  if [ -f "$USER_DIR/$s/SKILL.md" ] && ! cmp -s "$USER_DIR/$s/SKILL.md" "$src/SKILL.md"; then
    echo "INFO  user-level $USER_DIR/$s/SKILL.md differs from $SRC_ROOT/$s/SKILL.md (not managed here)"
  fi
done
echo "skill-render: $DRIFT drifted or extra file(s) across $N rendered file(s) in $REPO"
[ "$DRIFT" -gt 0 ] && exit 1
exit 0
