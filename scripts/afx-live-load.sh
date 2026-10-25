#!/bin/bash
# afx-live-load.sh (#16): this machine's own live load/memory/disk right now, as one
# JSON line. Closes the "roles + live load" half of the machine registry (#16) that
# fleet.json intentionally doesn't carry: fleet.json is a git-committed, shared-by-
# every-machine file (read from the hub's origin/main), so it can only ever hold
# STATIC facts (role, RAM, layout) - live telemetry for a machine that isn't running
# right now has nowhere to be pushed to, and committing live numbers would just be
# stale-by-the-next-commit noise. The fix: every machine can report ITS OWN live
# numbers on demand, in one standard shape, and a dashboard (or a human) queries each
# machine that's currently up rather than expecting one central store of everyone's
# live state. See afx-fleet.mjs --live, which wraps this for "this device" when
# building the fleet view.
#
#   afx-live-load.sh [--json]
#
# Uses afx_platform_load1 / afx_platform_mem_summary / afx_platform_swap_used_gb /
# afx_platform_disk_free_gb / afx_platform_ncpu (afx-platform.sh) - already portable
# across Mac/Linux/Windows, nothing new to port here.
set -u
_D="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
. "$_D/afx-platform.sh"

JSON=0
for a in "$@"; do case "$a" in --json) JSON=1 ;; -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]:-$0}" | sed '$d;s/^# \{0,1\}//'; exit 0 ;; *) echo "afx-live-load: unknown argument $a" >&2; exit 2 ;; esac; done

OS="$(afx_platform_os)"
LOAD1="$(afx_platform_load1 2>/dev/null)"; LOAD1="${LOAD1:-0}"
NCPU="$(afx_platform_ncpu 2>/dev/null)"; NCPU="${NCPU:-0}"
DISK_FREE_GB="$(afx_platform_disk_free_gb "$HOME" 2>/dev/null)"; DISK_FREE_GB="${DISK_FREE_GB:-0}"
SWAP_USED_GB="$(afx_platform_swap_used_gb 2>/dev/null)"
MEM_SUMMARY="$(afx_platform_mem_summary 2>/dev/null)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "$JSON" = 1 ]; then
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  printf '{"ts":"%s","os":"%s","load1":%s,"ncpu":%s,"diskFreeGb":%s,"swapUsedGb":%s,"memSummary":"%s"}\n' \
    "$NOW" "$OS" "$LOAD1" "$NCPU" "$DISK_FREE_GB" "${SWAP_USED_GB:-null}" "$(esc "$MEM_SUMMARY")"
else
  printf 'os=%s load1=%s ncpu=%s diskFreeGb=%s swapUsedGb=%s mem: %s (as of %s)\n' \
    "$OS" "$LOAD1" "$NCPU" "$DISK_FREE_GB" "${SWAP_USED_GB:-?}" "$MEM_SUMMARY" "$NOW"
fi
