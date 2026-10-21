#!/bin/bash
# afx-freeze.sh: declare / lift a machine-wide freeze on heavy local work (R21).
# While a freeze is on, the Claude Code policy hook blocks local pnpm install/build/typecheck/tsc,
# xcodebuild, pod install and expo export/prebuild in every session EXCEPT repos on the allow list.
# Remote gates (afx-remote-gate.sh) and ssh are never blocked.
#   afx-freeze.sh on "<reason>" <repo> [<repo>...]    e.g. on "app 1.0.30 TestFlight ship" my-app
#   afx-freeze.sh off
#   afx-freeze.sh status
set -u
_D="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
. "$_D/afx-platform.sh"
_m=$(afx_config_get clonesRootMac)
ROOT="${AFX_CLONES_ROOT:-${_m/#\~/$HOME}}"
F="$ROOT/.caches/afx-freeze"
case "${1:-status}" in
  on)
    [ $# -ge 3 ] || { echo "usage: afx-freeze.sh on \"<reason>\" <repo> [<repo>...]" >&2; exit 64; }
    reason="$2"; shift 2
    mkdir -p "$(dirname "$F")"
    printf 'reason: %s\nallow: %s\nsince: %s\nby: %s\n' "$reason" "$*" "$(date '+%Y-%m-%d %H:%M %Z')" "${AFX_SESSION_NAME:-$(whoami)}" > "$F"
    cat "$F" ;;
  off)
    if [ -f "$F" ]; then mv "$F" "$F.lifted-$(date +%Y%m%d-%H%M)"; echo "freeze lifted"; else echo "no freeze"; fi ;;
  status)
    if [ -f "$F" ]; then cat "$F"; else echo "no freeze"; fi ;;
  *) echo "usage: afx-freeze.sh on|off|status" >&2; exit 64 ;;
esac
