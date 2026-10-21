#!/bin/bash
# afx-lock.sh — the portfolio-wide Xcode/simulator lock. It replaces hand-rolled
# "while [ -f lock ]" loops. Only ONE xcodebuild / simulator job may run on this
# Mac at a time.
#
#   source scripts/afx-guard/afx-lock.sh
#   afx_lock_acquire "PYP" "archive-202609251728" || exit 1   # waits up to AFX_LOCK_WAIT_S
#   ... work ...
#   afx_lock_release
#
# Lock file format (one line): <owner> <pid> <UTC ISO start> <label>
# A lock is STALE, and is removed automatically, when its pid is no longer alive
# or it is older than AFX_LOCK_MAX_AGE_S. A dead holder (for example an agent
# killed mid-run) must never block the fleet. That happened on 2026-09-25.
#
# Portable: name of the lock notwithstanding ("Xcode/simulator"), the lock
# primitive itself (stale-pid detection, max-age, single-writer release) is
# generic and used on Linux repls and Windows/Git Bash too (e.g. the heavy-
# build lock). Date parsing (BSD `date -j -f` vs GNU `date -d`) goes through
# afx-platform.sh so this file is unchanged across platforms.

_AFX_LOCK_DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
. "$_AFX_LOCK_DIR/afx-platform.sh"

AFX_LOCK_FILE="${AFX_LOCK_FILE:-/tmp/afx-xcodebuild.lock}"
AFX_LOCK_WAIT_S="${AFX_LOCK_WAIT_S:-3600}"      # how long to wait for a live holder
AFX_LOCK_MAX_AGE_S="${AFX_LOCK_MAX_AGE_S:-5400}" # 90 min: no single job legitimately holds longer

_afx_lock_is_stale() {
  [ -f "$AFX_LOCK_FILE" ] || return 1
  local pid started now age
  pid=$(awk '{print $2}' "$AFX_LOCK_FILE" 2>/dev/null)
  started=$(awk '{print $3}' "$AFX_LOCK_FILE" 2>/dev/null)
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    echo "afx-lock: holder pid ${pid:-?} is dead -> stale" >&2; return 0
  fi
  if [ -n "$started" ]; then
    now=$(date -u +%s)
    age=$(( now - $(afx_platform_date_to_epoch "$started" 2>/dev/null || echo "$now") ))
    if [ "$age" -gt "$AFX_LOCK_MAX_AGE_S" ]; then
      echo "afx-lock: held ${age}s (> ${AFX_LOCK_MAX_AGE_S}s) by live pid $pid -> treat as hung, report it" >&2; return 0
    fi
  fi
  return 1
}

afx_lock_acquire() {
  local owner="$1" label="$2" waited=0
  while [ -f "$AFX_LOCK_FILE" ]; do
    if _afx_lock_is_stale; then
      echo "afx-lock: removing stale lock: $(cat "$AFX_LOCK_FILE")" >&2
      rm -f "$AFX_LOCK_FILE"; break
    fi
    if [ "$waited" -ge "$AFX_LOCK_WAIT_S" ]; then
      echo "afx-lock: gave up after ${waited}s; holder: $(cat "$AFX_LOCK_FILE")" >&2; return 1
    fi
    [ $(( waited % 300 )) -eq 0 ] && echo "afx-lock: waiting on $(cat "$AFX_LOCK_FILE") (${waited}s)" >&2
    sleep 15; waited=$(( waited + 15 ))
  done
  echo "$owner $$ $(date -u +%Y-%m-%dT%H:%M:%SZ) $label" > "$AFX_LOCK_FILE"
  # Remember WHICH file we locked: callers often pass AFX_LOCK_FILE as a one-call
  # prefix (AFX_LOCK_FILE=... afx_lock_acquire), which does not persist to the
  # EXIT trap. Releasing the default file instead leaked /tmp/afx-heavy-build.lock
  # on 2026-09-26 and stalled the next build for 19 minutes.
  _AFX_LOCK_HELD="$AFX_LOCK_FILE"
  trap 'afx_lock_release' EXIT
}

afx_lock_release() {
  # Only remove the lock if WE hold it (same pid), never someone else's.
  local f="${_AFX_LOCK_HELD:-$AFX_LOCK_FILE}"
  if [ -f "$f" ] && [ "$(awk '{print $2}' "$f")" = "$$" ]; then rm -f "$f"; fi
  _AFX_LOCK_HELD=""
}
