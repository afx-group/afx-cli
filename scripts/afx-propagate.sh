#!/bin/bash
# afx-propagate.sh: push a hub change out to every live repo with ONE command and a short answer (token-light for agents).
#   afx-propagate.sh rules [--apply] [--only key[,key...]] [--title TEXT]
# rules: re-render the shared agent-rules block into every live repo's rules files (AGENTS.md, replit.md, Cursor rule, Copilot
#   instructions, CONVENTIONS.md): one docs-only pull request per repo, landed one at a time (afx-agent-rules-rollout.sh).
#   It always runs the CURRENT rollout script and template, exported from the hub's origin/main, never a stale checkout.
#   Without --apply it only reports which repos have a clone on this machine (read-only; it compares LOCAL files, and clones can lag
#   origin/main, so "differs" can be a false alarm: --apply checks origin/main and skips repos already current).
#   The full per-repo output goes to ~/.afx/logs/propagate-rules-<stamp>.log; this script prints the summary only.
# Env: AFX_HUB (hub clone), AFX_PROJECTS_JSON (this machine's registry), AFX_COMMIT_TRAILER (attribution lines for each commit),
#      AFX_PROPAGATE_SCRIPTS (use this scripts/afx-guard folder instead of exporting origin/main; tests).
# Exit: 0 ok, 1 a repo failed, 2 usage / hub not found.
set -u
G="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
[ -f "$G/afx-platform.sh" ] && . "$G/afx-platform.sh"

what="${1:-}"; [ $# -gt 0 ] && shift
APPLY=0; ONLY=""; TITLE="docs(rules): refresh the shared agent-rules block (afx propagate rules)"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "afx propagate: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ "$what" = "rules" ] || { echo "usage: afx propagate rules [--apply] [--only key,key]   (more kinds to come)" >&2; exit 2; }

HUB="${AFX_HUB:-$(sed -n 's/^hub=//p' "$HOME/.claude/hooks/afx-guard/machine.conf" 2>/dev/null | head -1)}"
REG="${AFX_PROJECTS_JSON:-}"
if [ -z "$REG" ] && type afx_config_get >/dev/null 2>&1; then REG=$(afx_config_get registryFile 2>/dev/null); REG="${REG/#\~/$HOME}"; fi
LOGDIR="$HOME/.afx/logs"; mkdir -p "$LOGDIR" "$HOME/.afx/build"
LOG="$LOGDIR/propagate-rules-$(date +%Y%m%d-%H%M%S)-$$.log"

SCRIPTS="${AFX_PROPAGATE_SCRIPTS:-}"; TMP=""
if [ -z "$SCRIPTS" ]; then
  [ -n "$HUB" ] && [ -d "$HUB/.git" ] || { echo "afx propagate: hub clone not found (set hub= in machine.conf or AFX_HUB)" >&2; exit 2; }
  TMP="$HOME/.afx/build/propagate.$$"; mkdir -p "$TMP"
  git -C "$HUB" fetch -q origin main 2>/dev/null
  git -C "$HUB" archive origin/main scripts/afx-guard | tar -x -C "$TMP" || { echo "afx propagate: could not export origin/main from $HUB" >&2; rm -rf "$TMP"; exit 2; }
  SCRIPTS="$TMP/scripts/afx-guard"
fi
trap '[ -n "$TMP" ] && rm -rf "$TMP"' EXIT
ROLL="$SCRIPTS/afx-agent-rules-rollout.sh"
[ -f "$ROLL" ] || { echo "afx propagate: $ROLL not found" >&2; exit 2; }

args=(--projects "$SCRIPTS/registry/projects.json" --registry "$REG" --title "$TITLE")
[ -n "$ONLY" ] && args+=(--only "$ONLY")
[ "$APPLY" = 1 ] && args+=(--apply)
bash "$ROLL" "${args[@]}" > "$LOG" 2>&1
rc=$?

if [ "$APPLY" = 1 ]; then
  summary=$(grep -E '^rollout:' "$LOG" | tail -1)
  echo "rules: ${summary:-no summary line (see log)}"
  failed=$(grep -E '^failed ' "$LOG" | sed -E 's/^failed +([^:]+):.*/\1/' | tr '\n' ' ')
  [ -n "$failed" ] && echo "failed: $failed"
  echo "log: $LOG"
else
  n=$(grep -cE '^(DIFFERS|current) ' "$LOG"); d=$(grep -cE '^DIFFERS ' "$LOG")
  echo "rules (dry run, local clones): $d of $n differ. Run: afx propagate rules --apply   (it checks origin/main and skips repos already current)"
  echo "log: $LOG"
fi
exit $rc
