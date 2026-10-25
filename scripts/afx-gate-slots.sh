#!/bin/bash
# afx-gate-slots.sh: counting lock for install/typecheck/test gates on this Mac (default 3 slots; M1 Max 64 GB).
# Lives in scripts/afx-guard/ so every checkout has it. Xcode archives and simulators keep the separate
# single afx-lock.sh Xcode lock; this one only bounds concurrent install/tsc/test jobs.
#
#   source scripts/afx-guard/afx-gate-slots.sh
#   afx_gate_acquire "<REPO>" "<label>" || exit 97      # waits up to AFX_GATE_WAIT_S (default 3600)
#   ... ONE install OR one tsc/test pass ...
#   afx_gate_release
# or the wrapper:  scripts/afx-guard/afx-gate-run.sh <REPO> <label> -- <command...>
#
# Acquire and release inside ONE bash invocation (the lock is pid-based; a dead holder is reclaimed by afx-lock.sh).
# Slot 0 is the original heavy-gate.lock, so agents on the old single-lock recipe still count as a slot.
_AFX_GATE_GUARD="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
. "$_AFX_GATE_GUARD/afx-platform.sh"
. "$_AFX_GATE_GUARD/afx-lock.sh"
_AFX_GATE_DIR="${AFX_GATE_DIR:-${AFX_CLONES_ROOT:-$(afx_platform_clones_root)}/.caches/lead-agent}"

# Liveness markers (2026-10-23): while this shell waits for or holds a slot it keeps $_AFX_GATE_DIR/gate-activity/<pid>.json
# {pid,state waiting|holding,owner,label,cwd,since}. afx-status-collect.sh and the health reaper read them so a slot-starved agent is not
# reported stale or reaped. Best effort only (never fails or delays the gate); a marker whose pid is gone is ignored by the readers.
_afx_gate_mark() {  # _afx_gate_mark <waiting|holding> <owner> <label>
  local d="$_AFX_GATE_DIR/gate-activity" o l c
  o="$(printf '%s' "$2" | tr -d '"\\\n')"; l="$(printf '%s' "$3" | tr -d '"\\\n')"; c="$(printf '%s' "$PWD" | tr -d '"\\\n')"
  mkdir -p "$d" 2>/dev/null && printf '{"pid":%s,"state":"%s","owner":"%s","label":"%s","cwd":"%s","since":%s}\n' "$$" "$1" "$o" "$l" "$c" "$(date +%s)" > "$d/$$.json.tmp" 2>/dev/null && mv -f "$d/$$.json.tmp" "$d/$$.json" 2>/dev/null
  return 0
}
_afx_gate_unmark() { rm -f "$_AFX_GATE_DIR/gate-activity/$$.json" 2>/dev/null; return 0; }

afx_gate_acquire() {
  local owner="$1" label="$2" slots="${AFX_GATE_SLOTS:-3}" limit="${AFX_GATE_WAIT_S:-3600}" waited=0 i f
  mkdir -p "$_AFX_GATE_DIR"
  local marked=0
  while :; do
    i=0
    while [ "$i" -lt "$slots" ]; do
      if [ "$i" -eq 0 ]; then f="$_AFX_GATE_DIR/heavy-gate.lock"; else f="$_AFX_GATE_DIR/heavy-gate-$i.lock"; fi
      if AFX_LOCK_FILE="$f" AFX_LOCK_WAIT_S=0 afx_lock_acquire "$owner" "$label" 2>/dev/null; then
        _afx_gate_mark holding "$owner" "$label"; echo "afx-gate: slot $i acquired ($f)" >&2; return 0
      fi
      i=$(( i + 1 ))
    done
    [ "$marked" = 1 ] || { _afx_gate_mark waiting "$owner" "$label"; marked=1; }
    if [ "$waited" -ge "$limit" ]; then _afx_gate_unmark; echo "afx-gate: gave up after ${waited}s; all $slots slots busy" >&2; return 1; fi
    [ $(( waited % 300 )) -eq 0 ] && echo "afx-gate: all $slots slots busy, waiting (${waited}s)" >&2
    sleep "${AFX_GATE_POLL_S:-15}"; waited=$(( waited + ${AFX_GATE_POLL_S:-15} ))
  done
}
afx_gate_release() { _afx_gate_unmark; afx_lock_release; }
