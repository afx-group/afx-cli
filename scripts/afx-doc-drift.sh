#!/bin/bash
# afx-doc-drift.sh: READ-ONLY fleet report of the drift that makes a new terminal start with a wrong picture.
#
#   scripts/afx-guard/afx-doc-drift.sh [--clones-root DIR] [--fetch] [--only name1,name2] [--write FILE]
#
# For every git repo directly under the clones root it reports, from refs it already has (no network unless --fetch):
#   behind / ahead   local main versus origin/main
#   unique           local-only commits that are neither empty nor already upstream by patch (real work at risk)
#   staging          lines in CLAUDE.md / AGENTS.md / README.md / replit.md (on origin/main) that still call `staging` a PR or merge target
#   deployonly       lines that still say Replit is "a deployment target, not a development source" (retired 2026-10-13)
#   snews            lines naming the retired "snews" (a documented legacy shim is allowed; this does not separate them)
#   rules            the generated agent-rules block versus the hub template: OK | DRIFT | MISSING
# It never writes to a repo, never fetches unless asked, never changes a branch. Exit 0 always (it is a report);
# exit 2 on a usage error. --write FILE also saves the table (the nightly sweep can use it).
# Portable: bash 3.2 + git + python3 not required.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT=""; FETCH=0; ONLY=""; OUTF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --clones-root) ROOT="$2"; shift 2;;
    --fetch) FETCH=1; shift;;
    --only) ONLY="$2"; shift 2;;
    --write) OUTF="$2"; shift 2;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "afx-doc-drift: unknown argument $1" >&2; exit 2;;
  esac
done
[ -z "$ROOT" ] && ROOT="$(cd "$HERE/../../.." 2>/dev/null && pwd)"
[ -d "$ROOT" ] || { echo "afx-doc-drift: no such clones root: $ROOT" >&2; exit 2; }
SYNC="$HERE/afx-agent-rules-sync.sh"
FILES="CLAUDE.md AGENTS.md README.md replit.md"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LINES="$(printf '%-26s %-6s %-6s %-7s %-8s %-10s %-6s %s\n' repo behind ahead unique staging deployonly snews rules)"
OUTTXT="$LINES"$'\n'

for d in "$ROOT"/*/; do
  d="${d%/}"; n="$(basename "$d")"
  [ -e "$d/.git" ] || continue
  if [ -n "$ONLY" ]; then case ",$ONLY," in *",$n,"*) ;; *) continue;; esac; fi
  [ "$FETCH" = 1 ] && git -C "$d" fetch origin main -q 2>/dev/null
  git -C "$d" rev-parse --verify -q origin/main >/dev/null || { OUTTXT="$OUTTXT$(printf '%-26s %s' "$n" 'no origin/main ref')"$'\n'; continue; }
  git -C "$d" rev-parse --verify -q main >/dev/null || { OUTTXT="$OUTTXT$(printf '%-26s %s' "$n" 'no local main')"$'\n'; continue; }
  behind="$(git -C "$d" rev-list --count main..origin/main 2>/dev/null)"
  ahead="$(git -C "$d" rev-list --count origin/main..main 2>/dev/null)"
  uniq=0
  if [ "${ahead:-0}" -gt 0 ]; then
    for s in $(git -C "$d" cherry origin/main main 2>/dev/null | awk '$1=="+"{print $2}'); do
      pc="$(git -C "$d" rev-list --parents -n1 "$s" | wc -w | tr -d ' ')"
      if [ "$pc" -le 2 ] && [ "$(git -C "$d" rev-parse "$s^{tree}")" = "$(git -C "$d" rev-parse "$s^1^{tree}" 2>/dev/null)" ]; then continue; fi
      uniq=$((uniq+1))
    done
  fi
  txt=""
  for f in $FILES; do txt="$txt$(git -C "$d" show "origin/main:$f" 2>/dev/null)"$'\n'; done
  staging="$(printf '%s' "$txt" | grep -c -i -E '(target|merge|PR|pull request|branch).{0,40}staging|staging.{0,40}(target|merge)' | tr -d ' ')"
  deploy="$(printf '%s' "$txt" | grep -c -i 'deployment target, not a development source' | tr -d ' ')"
  snews="$(printf '%s' "$txt" | grep -c -i 'snews' | tr -d ' ')"
  rules="MISSING"
  if git -C "$d" cat-file -e "origin/main:AGENTS.md" 2>/dev/null && [ -x "$SYNC" ]; then
    rm -rf "$TMP/r"; mkdir -p "$TMP/r"
    want=""
    for p in AGENTS.md replit.md CONVENTIONS.md CLAUDE.md .cursor/rules/afx-operating-standard.mdc .github/copilot-instructions.md; do
      git -C "$d" cat-file -e "origin/main:$p" 2>/dev/null && want="$want $p"
    done
    [ -n "$want" ] && git -C "$d" archive origin/main $want 2>/dev/null | tar -x -C "$TMP/r" 2>/dev/null
    if bash "$SYNC" --check "$TMP/r" >/dev/null 2>&1; then rules="OK"; else rules="DRIFT"; fi
  fi
  OUTTXT="$OUTTXT$(printf '%-26s %-6s %-6s %-7s %-8s %-10s %-6s %s' "$n" "${behind:-?}" "${ahead:-?}" "$uniq" "$staging" "$deploy" "$snews" "$rules")"$'\n'
done

printf '%s' "$OUTTXT"
echo "-- read-only report; refs as of the last fetch (use --fetch to refresh). unique>0 means real, not-upstream work sits only on a local main."
[ -n "$OUTF" ] && { printf '%s' "$OUTTXT" > "$OUTF"; echo "wrote $OUTF"; }
exit 0
