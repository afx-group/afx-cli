#!/bin/bash
# afx-preflight.sh: run BEFORE fanning out agents, starting a build, or creating
# worktrees. Prints a one-screen health report; exit 1 means do not start heavy work.
# Portable: runs on macOS, Linux (Replit repls) and Windows (Git Bash). The
# Xcode/simulator-specific checks are skipped (not failed) off macOS.
#
#   scripts/afx-guard/afx-preflight.sh [--min-free-gb 20] [--max-load N] [--clones-root <dir>]
#     (load limit default: machine.conf max_load=N, else max(12, ceil(cores*1.5)); decision uses the 5m load average)
#     [--max-swap-gb 4] [--fail-on-booted-sim] [--fix]
#
# --max-swap-gb (L-001, default 4): Mac-only. FAILs when `vm.swapusage`
#   reports more than this many GB used — the 2026-09-26 PYP incident's swap
#   thrash (5.2/6 GB) made every build/sim step time out for a non-code
#   reason; catching it here means "ask the owner for a restart" happens
#   BEFORE a 30-minute wasted build, not after.
# --fail-on-booted-sim (L-002, opt-in for backward compat — existing callers
#   that only want the WARN keep getting it unless they pass this flag):
#   FAILs (not just warns) when any simulator is booted, regardless of
#   whether a lock file is present. A booted simulator runs daemons
#   (assetsd, AMS, diskimagesiod) indefinitely and both starves and
#   mis-attributes load during an xcodebuild step. afx-ship-ios.sh passes
#   this flag.
# --fix (A-ops-1, opt-in, Mac-only, default off — never changes behavior
#   unless explicitly passed): a wedged disposable simulator can masquerade
#   as "the machine is just generically busy" — one orphaned afx-check-warm
#   device with a pinned diskimagesiod dropped load from ~270 to ~2 the
#   instant it was shut down (2026-09-26/27). When a simulator is booted AND
#   the xcode lock is confirmed unheld (no lock file, or the lock's pid is
#   dead — never while a live build holds it, that would be destructive),
#   this runs `xcrun simctl shutdown all`, deletes any stale `afx-check-*`
#   device other than the persistent `afx-check-warm` one (deleting THAT one
#   would force the next check into a 6+ minute first-boot storm, L-003),
#   and reports load before/after.
set -u
DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "$0")" && pwd)}"
. "$DIR/afx-platform.sh"
MIN_FREE_GB=20; MAX_LOAD=""; MIN_MAX_LOAD=0; CLONES_ROOT="$(afx_platform_clones_root)"
MAX_SWAP_GB="${AFX_MAX_SWAP_GB:-4}"; FAIL_ON_BOOTED_SIM=0; DO_FIX=0
while [ $# -gt 0 ]; do case "$1" in
  --min-free-gb) MIN_FREE_GB=$2; shift 2;;
  --max-load) MAX_LOAD=$2; shift 2;;
  --min-max-load) MIN_MAX_LOAD=$2; shift 2;;
  --clones-root) CLONES_ROOT=$2; shift 2;;
  --max-swap-gb) MAX_SWAP_GB=$2; shift 2;;
  --fail-on-booted-sim) FAIL_ON_BOOTED_SIM=1; shift;;
  --fix) DO_FIX=1; shift;;
  *) shift;;
esac; done
FAIL=0
OS="$(afx_platform_os)"
# Load limit is per machine, not a flat number (2026-10-13: a flat 12 was calibrated on an 8 GB / 4-core Mac and blocked a
# 10-core / 64 GB Mac whose real problem was other sessions, not RAM). Precedence: --max-load, then `max_load=N` in
# machine.conf (AFX_MACHINE_CONF), then max(12, ceil(cores * 1.5)). AFX_NCPU, AFX_LOAD_1M and AFX_LOAD_5M exist for tests.
NCPU="${AFX_NCPU:-$(afx_platform_ncpu 2>/dev/null)}"; case "$NCPU" in ''|*[!0-9]*) NCPU=4;; esac
if [ -z "$MAX_LOAD" ]; then
  CONF="${AFX_MACHINE_CONF:-$HOME/.claude/hooks/afx-guard/machine.conf}"
  MAX_LOAD="$(sed -n 's/^max_load=//p' "$CONF" 2>/dev/null | head -1)"
  case "$MAX_LOAD" in ''|*[!0-9]*) MAX_LOAD=$(( (NCPU * 3 + 1) / 2 )); [ "$MAX_LOAD" -lt 12 ] && MAX_LOAD=12;; esac
fi
# --min-max-load N: a floor, never a cap (gate-slot-wrapped work passes 40, so a machine.conf max_load ABOVE 40 still applies).
case "$MIN_MAX_LOAD" in ''|*[!0-9]*) MIN_MAX_LOAD=0;; esac
[ "$MAX_LOAD" -lt "$MIN_MAX_LOAD" ] 2>/dev/null && MAX_LOAD=$MIN_MAX_LOAD

FREE_GB=$(afx_platform_disk_free_gb "$DIR"); [ -z "$FREE_GB" ] && FREE_GB=0
echo "platform: $OS"
echo "disk free: ${FREE_GB}GB (min ${MIN_FREE_GB})"; [ "$FREE_GB" -lt "$MIN_FREE_GB" ] 2>/dev/null && { echo "  FAIL: free disk. Remove merged worktrees (git worktree remove), old archives/build output."; FAIL=1; }

LOAD1="${AFX_LOAD_1M:-$(afx_platform_load1 | awk '{print int($1+0.5)}')}"
LOAD5="${AFX_LOAD_5M:-$(uptime 2>/dev/null | sed -n 's/.*load averages*: *//p' | tr ',' ' ' | awk '{print int($2+0.5)}')}"
case "$LOAD5" in ''|*[!0-9]*) LOAD5="${LOAD1:-0}";; esac
LOAD="$LOAD5"   # decision uses the 5-minute average so a one-off spike does not block work
echo "load (1m/5m${OS:+, $OS}): ${LOAD1:-0}/${LOAD5} (max ${MAX_LOAD} on ${NCPU} cores; decision uses the 5m average)"
if [ "${LOAD:-0}" -gt "$MAX_LOAD" ] 2>/dev/null; then
  echo "  FAIL: load. Wait, or stop a chain; check for a stuck simulator/runaway build."
  FAIL=1
  # Say WHO is using the CPU, by repo where it can be told (best effort, bounded to 5 processes).
  echo "  top CPU consumers (percent, pid, repo or command):"
  if [ -n "${AFX_PS_FIXTURE:-}" ]; then PSOUT="$(cat "$AFX_PS_FIXTURE")"; else PSOUT="$(ps -Ao pcpu=,pid=,comm= 2>/dev/null | sort -rn | head -5)"; fi
  printf '%s\n' "$PSOUT" | while read -r pc pid comm; do
    [ -z "$pid" ] && continue
    where="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 | sed -n 's#.*/_clones/\([^/]*\).*#\1#p')"
    printf '    %5s%%  %-7s %s\n' "$pc" "$pid" "${where:-$(basename "$comm")}"
  done
fi
echo "memory: $(afx_platform_mem_summary)"

if [ "$OS" = linux ]; then
  # A repl's $HOME quota (~5 GB) is separate from, and much smaller than, the
  # disk-free figure above (that's the container's overlay filesystem). This
  # is what actually EDQUOT'd HTR's repl on 2026-09-27 — see afx-platform.sh's
  # afx_platform_home_quota_gb comment for the incident and the fix (#198/#199).
  HOME_GB=$(afx_platform_home_quota_gb)
  echo "home quota usage (excl. ~/workspace): ${HOME_GB}GB (warn above 4GB — separate, much smaller quota than disk free above)"
  awk -v g="${HOME_GB:-0}" 'BEGIN{exit !(g>4)}' 2>/dev/null && echo "  WARN: approaching the ~5GB repl home quota. Clean up stray checkouts/pnpm stores under \$HOME outside ~/workspace, or expect EDQUOT."
fi

if [ "$OS" = mac ]; then
  SWAP_GB=$(afx_platform_swap_used_gb)
  echo "swap used: ${SWAP_GB:-unknown}GB (max ${MAX_SWAP_GB}) — L-001"
  if [ -n "$SWAP_GB" ]; then
    awk -v s="$SWAP_GB" -v m="$MAX_SWAP_GB" 'BEGIN{exit !(s>m)}' && { echo "  FAIL: swap thrash (L-001). Every build/sim step will silently run slow or time out for a non-code reason. Ask the owner for a restart before starting heavy work."; FAIL=1; }
  fi
  LOCK=/tmp/afx-xcodebuild.lock
  if [ -f "$LOCK" ]; then P=$(awk '{print $2}' "$LOCK"); if kill -0 "$P" 2>/dev/null; then echo "xcode lock: held by live pid $P: $(cat "$LOCK")"; else echo "xcode lock: STALE (pid $P dead). afx_lock_acquire will clear it."; fi; else echo "xcode lock: free"; fi
  BOOTED=$(xcrun simctl list devices booted 2>/dev/null | grep -c Booted); echo "booted simulators: $BOOTED"
  if [ "$BOOTED" -gt 0 ]; then
    if [ "$FAIL_ON_BOOTED_SIM" = 1 ]; then
      echo "  FAIL: simulator booted (L-002). Never start xcodebuild with a simulator running (assetsd/AMS/diskimagesiod daemons starve load indefinitely). Run: xcrun simctl shutdown all"
      FAIL=1
    elif [ ! -f "$LOCK" ]; then
      echo "  WARN: simulator booted with no lock holder. Run: xcrun simctl shutdown all (or re-run with --fix)."
    fi
  fi
  if [ "$BOOTED" -gt 0 ] && [ "$DO_FIX" = 1 ]; then
    if ! afx_platform_require_mac "afx-preflight.sh --fix" >/dev/null 2>&1; then
      echo "  --fix: skipped (Mac-only)"
    else
      LOCK_LIVE=0
      if [ -f "$LOCK" ]; then LP=$(awk '{print $2}' "$LOCK"); kill -0 "$LP" 2>/dev/null && LOCK_LIVE=1; fi
      if [ "$LOCK_LIVE" = 1 ]; then
        echo "  --fix: SKIPPED — xcode lock is held by live pid $LP; shutting down simulators now would be destructive to that build."
      else
        LOAD_BEFORE=$(afx_platform_load1)
        echo "  --fix: load before = ${LOAD_BEFORE:-unknown}"
        xcrun simctl shutdown all >/dev/null 2>&1
        xcrun simctl list devices -j 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
for _rt, ds in data.get("devices", {}).items():
    for d in ds:
        name = d.get("name", "")
        if name.startswith("afx-check-") and name != "afx-check-warm":
            print(d["udid"])
' 2>/dev/null | while IFS= read -r udid; do
          [ -n "$udid" ] || continue
          xcrun simctl delete "$udid" >/dev/null 2>&1 && echo "  --fix: deleted stale simulator device $udid (kept afx-check-warm)"
        done
        sleep 2
        LOAD_AFTER=$(afx_platform_load1)
        echo "  --fix: shut down all simulators. load before=${LOAD_BEFORE:-unknown} after=${LOAD_AFTER:-unknown}"
      fi
    fi
  fi
  HUNG=$(ps -Ao etime=,command= 2>/dev/null | awk '$2 ~ /simctl|xcodebuild/ {split($1,a,"[-:]"); n=length(a); s=a[n]+a[n-1]*60+(n>=3?a[n-2]*3600:0)+(n>=4?a[n-3]*86400:0); if (s>2700) print "  HUNG? " $0}')
  [ -n "$HUNG" ] && { echo "long-running simctl/xcodebuild (>45 min):"; echo "$HUNG"; FAIL=1; }
else
  echo "xcode lock / simulators: skipped (Mac-only, running on $OS)"
fi

if [ -d "$CLONES_ROOT" ]; then
  for r in "$CLONES_ROOT"/*/; do
    [ -d "$r/.git" ] || [ -f "$r/.git" ] || continue
    n=$(git -C "$r" worktree list 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    [ "${n:-0}" -gt 6 ] && echo "worktrees: $(basename "$r") has $n; remove merged ones"
  done
else
  echo "worktrees: skipped (clones root not found: $CLONES_ROOT; pass --clones-root)"
fi

# Guard freshness (sync-guard b): warn (never FAIL) if this guard's own repo checkout is
# behind its origin/main — heavy work shouldn't run on a stale guard/code checkout, and a
# stale guard means stale rules. Uses the local remote-tracking ref only (no network, fast);
# it reflects the last fetch. Skipped when the guard runs from the standalone ~/.claude copy
# (not a git repo). $DIR is scripts/afx-guard, so ../.. is the repo root.
GUARD_REPO="$(cd "$DIR/../.." 2>/dev/null && pwd)"
if [ -n "$GUARD_REPO" ] && git -C "$GUARD_REPO" rev-parse --git-dir >/dev/null 2>&1 \
   && git -C "$GUARD_REPO" rev-parse --verify -q origin/main >/dev/null 2>&1; then
  BEHIND=$(git -C "$GUARD_REPO" rev-list --count HEAD..origin/main 2>/dev/null)
  if [ "${BEHIND:-0}" -gt 0 ] 2>/dev/null; then
    echo "guard freshness: WARN — $(basename "$GUARD_REPO") is ${BEHIND} commit(s) behind origin/main (as of the last fetch). Run 'git -C $GUARD_REPO fetch origin main && git merge --ff-only origin/main' and refresh the installed guard before heavy work."
  else
    echo "guard freshness: up to date with origin/main (as of the last fetch)."
  fi
fi
exit $FAIL
