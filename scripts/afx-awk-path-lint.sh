#!/bin/bash
# afx-awk-path-lint.sh: fail `awk '{print $N}'`-style field extraction
# applied to command output that can contain a path (worktree list, find,
# ls, or any line that visibly carries a filesystem path) inside
# scripts/afx-guard.
#
#   scripts/afx-guard/afx-awk-path-lint.sh [scripts/afx-guard-dir ...]
#     (default: this script's own directory)
#
# A-XPLAT-13 (hub #206, afx-worktree-clean.sh): awk splits on whitespace, so
# a worktree path containing a space ("How To Raise") was silently truncated
# to "How" — nothing errored, the tool just reported/acted on the wrong
# path. Use `sed -n 's/^prefix //p'` to take "everything after a known
# prefix" instead; see afx-fragment-audit.sh / afx-preserve-all.sh /
# afx-worktree-clean.sh for the fixed pattern.
#
# Deliberately scoped, not a blanket "awk print $N" ban: afx-lock.sh (pid
# extraction), afx-platform.sh (numeric disk/load/memory fields) and
# afx-sim-check.sh all use `awk '{print $N}'` correctly on fixed-format,
# space-free numeric/token output — those are NOT path-bearing and are not
# flagged. This only flags awk piped directly from a command whose output is
# a filesystem path (worktree list/add/remove, find, ls, realpath, pwd,
# dirname/basename), which is exactly the class of value that can contain
# spaces on this portfolio (repo names like "How To Raise", "Park Your Pup").
set -u
DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
. "$DIR/afx-platform.sh"

ROOTS=("$@")
[ ${#ROOTS[@]} -eq 0 ] && ROOTS=("$DIR")

# A path-bearing source piped (directly, or via other pipeline stages) into
# an awk print — matched anywhere on the same logical line as the awk call
# (this is a grep-based lint, not a real pipeline-dataflow analyzer, so it
# only catches the same-line case; that is exactly the shape every real
# incident in this portfolio has taken).
PATH_SOURCE_RE='(worktree (list|add|remove)|find[[:space:]]|[[:space:]]ls[[:space:]]|realpath|dirname|basename|[[:space:]]pwd([[:space:]]|$))'
AWK_PRINT_RE="awk[^|]*print[[:space:]]+\\\$[0-9]"

HITS=0
for root in "${ROOTS[@]}"; do
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    while IFS=: read -r lineno line; do
      [ -z "${lineno:-}" ] && continue
      echo "AWK_ON_PATH $f:$lineno:$line"
      HITS=$((HITS + 1))
    done < <(grep -nE "$PATH_SOURCE_RE" "$f" 2>/dev/null | grep -E "$AWK_PRINT_RE")
  done < <(find "$root" \( -name node_modules -o -name .git -o -path "$root/*/.claude/worktrees/*" \) -prune -o -type f \( -name "*.sh" -o -name "*.bash" \) -print 2>/dev/null)
done

echo "afx-awk-path-lint: $HITS awk-print-on-path-output pattern(s) found (see A-XPLAT-13)."
[ "$HITS" -gt 0 ] && exit 1
exit 0
