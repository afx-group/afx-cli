#!/bin/bash
# afx-guard-lint.sh: the single local-gate entry point for afx-guard's own
# portable, no-external-dependency lint checks. Run this (not each check
# individually) from a pre-commit hook, afx-remote-gate.sh, or by hand —
# every new grep/lint-style enforcement check added to afx-guard should be
# wired in here so there is one place that runs "all of them," matching this
# portfolio's "local gates only, never .github/workflows" policy.
#
#   scripts/afx-guard/afx-guard-lint.sh [root]   (default: this repo)
#
# Exit 0: every check passed. Exit 1: at least one failed (see which, above).
set -u
DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
. "$DIR/afx-platform.sh"
ROOT="${1:-$(cd "$DIR/../.." && pwd)}"

FAIL=0
run_check() {
  local name="$1"; shift
  echo "--- $name ---"
  "$@"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "GATE $name rc=$rc"
    FAIL=1
  else
    echo "GATE $name rc=0"
  fi
  echo ""
}

run_check "afx-cd-lint" "$DIR/afx-cd-lint.sh" "$ROOT"
# ps1-bom-lint and awk-path-lint are scoped to scripts/afx-guard itself
# (fully enforced, 0 violations there as of this change) rather than the
# whole repo — a repo-wide run surfaces ~36 additional pre-existing .ps1
# violations outside afx-guard (device-optimizer, a legacy archive copy)
# that belong to those files' own owners to ratchet down separately; run
# `afx-ps1-bom-lint.sh <root>` by hand against the whole tree for that audit.
run_check "afx-ps1-bom-lint" "$DIR/afx-ps1-bom-lint.sh" "$DIR"
run_check "afx-awk-path-lint" "$DIR/afx-awk-path-lint.sh" "$DIR"
# Vendored-drift (sync-guard c): a venture's copy of the shared guard scripts must match the
# hub's origin/main. Self-skips when run in the hub itself, or when no hub checkout is found.
run_check "afx-vendored-drift" "$DIR/afx-vendored-drift-lint.sh" "$ROOT"

# ADVISORY (never sets FAIL): flags hardcoded/fabricated values that may be rendered as
# live metrics (2026-10-01 readiness audit). Prints CANDIDATE lines for human review;
# a nonzero rc from this check is reported but does not fail the gate. Tighten later by
# passing --strict and treating rc=1 like the checks above. Scans $AFX_FAKE_DATA_ROOT
# (default: this repo's artifacts/ + packages/ if present, else the whole root).
echo "--- afx-fake-data-lint (advisory) ---"
FD_ROOTS=()
for d in artifacts packages lib apps; do [ -d "$ROOT/$d" ] && FD_ROOTS+=("$ROOT/$d"); done
[ ${#FD_ROOTS[@]} -eq 0 ] && FD_ROOTS=("$ROOT")
[ -n "${AFX_FAKE_DATA_ROOT:-}" ] && FD_ROOTS=("$AFX_FAKE_DATA_ROOT")
FD_OUT="$("$DIR/afx-fake-data-lint.sh" "${FD_ROOTS[@]}" 2>&1)"
printf '%s\n' "$FD_OUT" | grep '^CANDIDATE' | head -n "${AFX_FAKE_DATA_MAX_LINES:-10}"
printf '%s\n' "$FD_OUT" | grep -v '^CANDIDATE'
echo "(first ${AFX_FAKE_DATA_MAX_LINES:-10} shown; run afx-fake-data-lint.sh <root> for all)"
echo "GATE afx-fake-data-lint advisory (never blocks)"
echo ""

exit $FAIL
