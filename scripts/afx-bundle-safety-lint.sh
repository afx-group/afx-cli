#!/usr/bin/env bash
# afx-bundle-safety-lint.sh — catch code that drags test files into a production bundle.
# Root cause of the 2026-09-29 HTR outage: AuditPreviewPage used
#   import.meta.glob('/src/pages/**/*.tsx')
# which eagerly pulled *.test.tsx into the vendor chunk; the test file's vitest import threw
# "Vitest failed to access its internal state" at load and blanked the whole PWA for fresh
# visitors. This lint flags any import.meta.glob over a .ts/.tsx tree that does NOT exclude
# test files, so it can't recur across any AFX Vite app.
#
#   scripts/afx-guard/afx-bundle-safety-lint.sh <dir>   (defaults to CWD)
# Exit 0 = clean · 3 = a risky glob found. Portable: macOS / Linux / Git Bash (grep only).
set -u
DIR="${1:-.}"
cd "$DIR" 2>/dev/null || { echo "bundle-safety: dir not found: $DIR" >&2; exit 2; }

# Lines calling import.meta.glob with a .ts/.tsx pattern (eager or lazy).
HITS="$(grep -rInE "import\.meta\.glob\b" \
        --include=*.ts --include=*.tsx --include=*.js --include=*.jsx . 2>/dev/null \
        | grep -viE "\.test\.|/__tests__/|/node_modules/" || true)"

bad=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # Only care about globs that can match source modules (.tsx/.ts/* ).
  echo "$line" | grep -qE "import\.meta\.glob\(\s*[\[]?\s*['\"][^'\"]*(\*\*|\*)[^'\"]*['\"]" || continue
  # Safe if the SAME call excludes test files (negative glob) or filters by a non-test suffix.
  if echo "$line" | grep -qE "!.*(test|spec)|\.stories\.|['\"][^'\"]*\.(page|route|screen)\.tsx?['\"]"; then
    continue
  fi
  # A .tsx/.ts/generic glob with no test exclusion = risk.
  if echo "$line" | grep -qE "\*\*?/\*\.(tsx?|jsx?)|\*\*?/\*['\"]|\.\*['\"]"; then
    echo "RISK: import.meta.glob without a test-file exclusion — can pull *.test.* into the bundle:" >&2
    echo "  ${line}" | cut -c1-200 >&2
    echo "  fix: use an array glob with a negative, e.g. import.meta.glob(['/src/…/**/*.tsx','!**/*.test.*'])" >&2
    bad=1
  fi
done <<EOF
$HITS
EOF

if [ "$bad" -ne 0 ]; then echo "bundle-safety: FAIL (see above)"; exit 3; fi
echo "bundle-safety: OK — no import.meta.glob pulls test files into the bundle."
