#!/bin/bash
# afx-ps1-bom-lint.sh: fail any .ps1 file that contains non-ASCII bytes but
# has no UTF-8 BOM.
#
#   scripts/afx-guard/afx-ps1-bom-lint.sh [path-or-root ...]   (default: repo root)
#
# A-XPLAT-12 (hub #206): Windows PowerShell 5.1 reads a BOM-less .ps1 in the
# system ANSI codepage. An em-dash (or any non-ASCII byte, e.g. curly quotes,
# accented names) in a comment then decodes as something else entirely and
# throws a ParseException ("Unexpected token", "missing terminator") — this
# broke afx-worktree-remove.ps1 and afx-preserve-all.ps1 on the Lenovo. The
# fix is either add a UTF-8 BOM (EF BB BF) or keep the file pure ASCII;
# either satisfies this check.
set -u
DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
. "$DIR/afx-platform.sh"

ROOTS=("$@")
[ ${#ROOTS[@]} -eq 0 ] && ROOTS=(".")

HITS=0
for root in "${ROOTS[@]}"; do
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    # BOM check: first 3 bytes = EF BB BF.
    bom="$(head -c 3 "$f" | od -An -tx1 2>/dev/null | tr -d ' \n')"
    if [ "$bom" = "efbbbf" ]; then
      continue  # has a BOM — safe regardless of content
    fi
    # Non-ASCII check: any byte >= 0x80. ANSI-C quoting ($'...') embeds the
    # literal bytes into a plain POSIX bracket expression, so this works with
    # BSD grep (macOS) and GNU grep (Linux/Windows Git Bash) alike — no -P
    # (PCRE) dependency, which stock BSD grep doesn't have.
    if LC_ALL=C grep -q $'[\x80-\xFF]' "$f" 2>/dev/null; then
      echo "BOM_MISSING $f (contains non-ASCII bytes, no UTF-8 BOM — will misparse under Windows PowerShell 5.1's ANSI codepage)"
      HITS=$((HITS + 1))
    fi
  done < <(find "$root" \( -name node_modules -o -name .git -o -path "$root/*/.claude/worktrees/*" \) -prune -o -type f -name "*.ps1" -print 2>/dev/null)
done

echo "afx-ps1-bom-lint: $HITS .ps1 file(s) with non-ASCII content and no UTF-8 BOM."
[ "$HITS" -gt 0 ] && exit 1
exit 0
