#!/bin/bash
# afx-gate-capture.sh: run ONE gate command and print its REAL exit code,
# unconditionally — so a pipe (`cmd | tail -5 && echo OK`) can never mask a
# failure again.
#
#   scripts/afx-guard/afx-gate-capture.sh <name> -- <cmd...>
#
# L-021 (2026-09-17): a session ran
#   npx tsc --noEmit 2>&1 | tail -5 && echo "TypeScript OK"
# watched real `error TS1005` lines scroll past, and still reported "0
# errors / ALL GATES PASS" — because `tail`'s own exit code (0) is what
# `&&` sees, not tsc's. 47 real type errors shipped. This wraps a command so
# the ONLY thing printed at the end is `GATE <name> rc=<n>`, straight from
# `$?` of the command itself, never from a pipeline stage after it.
#
# Prints the command's own stdout/stderr as it runs (nothing is swallowed —
# use this in place of the bare command, not as a silence wrapper), then the
# `GATE` line. Exit code is the wrapped command's own exit code, unchanged,
# so `afx-gate-capture.sh foo -- some-cmd` is a drop-in replacement for
# `some-cmd` in a larger `&&`/`;` chain — the difference is purely that the
# real number gets printed and can't be lost to a downstream pipe.
#
#   scripts/afx-guard/afx-gate-capture.sh typecheck -- npx tsc --noEmit
#   scripts/afx-guard/afx-gate-capture.sh tests -- npm test
#
# Chaining multiple gates and wanting to know which one (if any) failed:
#   scripts/afx-guard/afx-gate-capture.sh typecheck -- npx tsc --noEmit \
#     && scripts/afx-guard/afx-gate-capture.sh tests -- npm test
# (each prints its own GATE line regardless of whether it's reached; a
# gate after a `&&` simply never runs — and never prints — if the one
# before it failed, which is the correct, honest behavior: it means "not
# run", not "passed".)
set -u
NAME="${1:-}"; shift 2>/dev/null || true
if [ "${1:-}" = "--" ]; then shift; fi
[ -n "$NAME" ] && [ $# -gt 0 ] || { echo "usage: afx-gate-capture.sh <name> -- <cmd...>" >&2; exit 3; }

"$@"
RC=$?
echo "GATE $NAME rc=$RC"
exit "$RC"
