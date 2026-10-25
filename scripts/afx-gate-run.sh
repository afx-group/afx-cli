#!/bin/bash
# afx-gate-run.sh <REPO> <label> -- <command...>: run ONE heavy command inside a gate slot and print its real exit code.
# This is the form the Claude policy hook recognises as "slot-wrapped" (heavy-work load gate honours the slots).
#
# Output discipline (token saving, deterministic, no model): the command's FULL output (secrets masked) goes to a log
# file and stdout carries only a digest from afx-digest.mjs plus three literal lines:
#   <digest: counts / failing names / last lines, chosen by command type>
#   LOG: <path>        LINES: <n>        EXIT: <rc>      (EXIT is always the last line)
# The digest never contains a verdict; the exit code is the command's own.
#   AFX_GATE_LOG=<path>       log file (default: $PWD/.gate-logs/<label>.log)
#   AFX_GATE_BASELINE=<file>  tsc baseline log -> adds net-new vs baseline to the digest
#   AFX_GATE_TYPE=<type>      force digest type: tsc|node-test|vitest|install|tail (default: auto from the command + log)
#   AFX_GATE_VERBOSE=1        print everything as before (output streams to stdout, then "EXIT: <rc>"); no log file.
set -u
D="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
[ $# -ge 4 ] && [ "$3" = "--" ] || { echo "usage: afx-gate-run.sh <REPO> <label> -- <command...>" >&2; exit 2; }
. "$D/afx-gate-slots.sh"
REPO="$1"; LABEL="$2"; shift 3
afx_gate_acquire "$REPO" "$LABEL" || exit 97
export AFX_IN_GATE_SLOT=1   # children (afx-ratchet.sh installs) must not take a second slot
if [ "${AFX_GATE_VERBOSE:-0}" = 1 ]; then
  "$@"; rc=$?
  afx_gate_release
  echo "EXIT: $rc"
  exit $rc
fi
SAFE="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9._-' '_')"
LOG="${AFX_GATE_LOG:-$PWD/.gate-logs/$SAFE.log}"
if ! mkdir -p "$(dirname "$LOG")" 2>/dev/null; then LOG="${TMPDIR:-/tmp}/afx-gate-$SAFE.$$.log"; fi
"$@" 2>&1 | "$D/afx-mask-secrets.sh" > "$LOG"
rc="${PIPESTATUS[0]}"
afx_gate_release
N="$(wc -l < "$LOG" | tr -d ' ')"
DARGS=(--cmd "$*")
[ -n "${AFX_GATE_TYPE:-}" ] && DARGS+=(--type "$AFX_GATE_TYPE")
[ -n "${AFX_GATE_BASELINE:-}" ] && DARGS+=(--baseline "$AFX_GATE_BASELINE")
if command -v node >/dev/null 2>&1; then
  # The log is already masked and the digest only quotes it, so the digest is not masked again (the masker
  # would rewrite harmless "pass=2" counters).
  node "$D/afx-digest.mjs" "${DARGS[@]}" < "$LOG" || { echo "digest unavailable; last 40 lines:"; tail -n 40 "$LOG"; }
else
  echo "digest unavailable (no node); last 40 lines:"; tail -n 40 "$LOG"
fi
echo "LOG: $LOG"
echo "LINES: $N"
echo "EXIT: $rc"
exit $rc
