#!/bin/bash
# afx-size-guard.sh: reject a commit that stages a file over the size limit
# unless that file is already Git-LFS-tracked. Catches the "173MB benchmark
# output committed by accident" class of mistake at commit time instead of
# three weeks later when a push gets rejected by GitHub's 100MB hard limit.
#
#   Install as a pre-commit hook:
#     ln -sf ../../scripts/afx-guard/afx-size-guard.sh .git/hooks/pre-commit
#   Or run manually before committing:
#     scripts/afx-guard/afx-size-guard.sh
#
# Env overrides:
#   AFX_SIZE_GUARD_LIMIT_MB (default 50)

set -euo pipefail

LIMIT_MB="${AFX_SIZE_GUARD_LIMIT_MB:-50}"
LIMIT_BYTES=$((LIMIT_MB * 1024 * 1024))
FAILED=0

# .gitattributes lines end "... filter=lfs ..." — build the set of
# LFS-tracked patterns so we don't flag files that are already handled.
LFS_PATTERNS=()
if [ -f .gitattributes ]; then
  while IFS= read -r line; do
    case "$line" in
      *filter=lfs*) LFS_PATTERNS+=("$(echo "$line" | awk '{print $1}')") ;;
    esac
  done < .gitattributes
fi

is_lfs_tracked() {
  local f="$1"
  for pat in "${LFS_PATTERNS[@]:-}"; do
    [ -n "$pat" ] && case "$f" in $pat) return 0 ;; esac
  done
  return 1
}

while IFS= read -r -d '' file; do
  [ -f "$file" ] || continue
  size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
  if [ "$size" -gt "$LIMIT_BYTES" ]; then
    if is_lfs_tracked "$file"; then
      continue
    fi
    mb=$((size / 1024 / 1024))
    echo "afx-size-guard: BLOCKED — $file is ${mb}MB (limit ${LIMIT_MB}MB) and not LFS-tracked." >&2
    echo "  Is it regeneratable test/benchmark/build output? -> add it to .gitignore instead." >&2
    echo "  Genuinely needs version control? -> add it to .gitattributes as LFS (see a project's" >&2
    echo "  .gitattributes for the pattern) or attach it to a GitHub Release instead." >&2
    echo "  See _readiness/AFX_LARGE_FILE_STORAGE_STANDARD.md (hub) for the full decision matrix." >&2
    FAILED=1
  fi
done < <(git diff --cached --name-only -z --diff-filter=ACM)

exit "$FAILED"
