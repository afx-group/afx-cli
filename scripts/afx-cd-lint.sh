#!/bin/bash
# afx-cd-lint.sh: find bare `cd` calls — ones with no `|| exit`/`|| return`
# guard — in our own shell scripts AND in agent-authored heredoc templates
# (the `cat <<EOF ... cd ... EOF` blocks that get shipped to a Replit repl
# over SSH). A coordinator slip committed onto a MAIN checkout on
# 2026-09-27 because a worktree-creation heredoc `cd`'d into a path without
# checking the worktree actually got created first — this script is the
# grep-based guard against a repeat.
#
#   scripts/afx-guard/afx-cd-lint.sh [path-or-root ...]   (default: repo root)
#
# Exit 0: no bare `cd` found. Exit 1: at least one found (printed as
# file:line). This is intentionally a blunt grep, not a shell parser — it
# will have false positives on a `cd` that IS guarded on the next line
# rather than the same line (e.g. `if ! cd "$X"; then exit; fi` across
# lines), and on a `cd` inside a string/comment. Treat a hit as "go look",
# not an automatic bug; the pattern this actually catches (a raw `cd $dir`
# with nothing after it) has caused two real incidents in this portfolio
# (L-015's HTR workspace commit, and the 2026-09-27 main-checkout commit),
# so a few false positives are an acceptable cost for catching those.
set -u
DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
. "$DIR/afx-platform.sh"

ROOTS=("$@")
[ ${#ROOTS[@]} -eq 0 ] && ROOTS=(".")

# A "safe" cd line: followed on the SAME line by `||`, `&&`, or `;` guard
# logic that plausibly checks the result, OR is immediately followed by
# `exit`/`return`/`{` continuation. We flag anything that is NOT that.
# Also treat `cd` as safe when it's `cd -` (return to OLDPWD, not a target
# that can silently fail the way a missing worktree dir does) or is inside
# a comment.
SAFE_RE='cd([[:space:]]+-|[^;&|\n]*(\|\||;[[:space:]]*$))'

HITS=0
FOUND_FILES=$(mktemp)
trap 'rm -f "$FOUND_FILES"' EXIT

for root in "${ROOTS[@]}"; do
  find "$root" \
    \( -name node_modules -o -name .git -o -name Pods -o -name build -o -path "$root/*/.claude/worktrees/*" -o -path "*/dist/*" \) -prune -o \
    -type f \( -name "*.sh" -o -name "*.bash" \) -print 2>/dev/null
done | sort -u > "$FOUND_FILES"

while IFS= read -r f; do
  [ -f "$f" ] || continue
  # Strip full-line comments before scanning so a `# cd foo` in a doc
  # comment doesn't false-positive.
  awk '
    {
      line = $0
      code = line
      sub(/^[[:space:]]*#.*/, "", code)
      if (code ~ /(^|[;&|[:space:]])cd([[:space:]]|$)/) {
        # Same-line guard? (||, or a trailing ; that starts an if/exit check
        # is too hard to grep reliably, so only credit an explicit ||.)
        if (code !~ /\|\|/ && code !~ /^[[:space:]]*cd[[:space:]]+-([[:space:]]|$)/) {
          print NR ":" line
        }
      }
    }
  ' "$f" > /tmp/afx-cd-lint.$$ 2>/dev/null
  if [ -s /tmp/afx-cd-lint.$$ ]; then
    while IFS= read -r hit; do
      echo "BARE_CD $f:$hit"
      HITS=$((HITS + 1))
    done < /tmp/afx-cd-lint.$$
  fi
  rm -f /tmp/afx-cd-lint.$$
done < "$FOUND_FILES"

# Same scan, but for heredoc bodies embedded in scripts that build remote
# command strings (the exact pattern that ships to a repl over SSH) — these
# live inside `<<EOF ... EOF` blocks in afx-remote-gate.sh-style scripts and
# would otherwise be scanned as plain script lines above (which already
# covers most cases since the heredoc body IS in a .sh file); this second
# pass additionally covers heredocs embedded in non-.sh files (e.g. a
# workflow script's inline agent template written in .md/.mjs/.py).
while IFS= read -r f; do
  [ -f "$f" ] || continue
  case "$f" in *.sh|*.bash) continue;; esac
  grep -nE "<<[-~]?['\"]?[A-Za-z_]+['\"]?" "$f" >/dev/null 2>&1 || continue
  awk '
    /<<[-~]?['"'"'"]?[A-Za-z_]+['"'"'"]?/ { in_heredoc=1 }
    in_heredoc {
      code = $0
      sub(/^[[:space:]]*#.*/, "", code)
      if (code ~ /(^|[;&|[:space:]])cd([[:space:]]|$)/ && code !~ /\|\|/ && code !~ /^[[:space:]]*cd[[:space:]]+-([[:space:]]|$)/) {
        print NR ":" $0
      }
    }
  ' "$f" 2>/dev/null | while IFS= read -r hit; do
    echo "BARE_CD_IN_HEREDOC $f:$hit"
  done
done < <(for root in "${ROOTS[@]}"; do
    find "$root" \( -name node_modules -o -name .git -prune \) -o -type f \( -name "*.md" -o -name "*.mjs" -o -name "*.py" \) -print 2>/dev/null
  done | sort -u)

echo "afx-cd-lint: $HITS bare 'cd' found in *.sh/*.bash (heredoc-in-other-filetypes hits, if any, printed above are advisory only and not counted)."
[ "$HITS" -gt 0 ] && exit 1
exit 0
