#!/bin/bash
# afx-lint-guard-scripts.sh: flag non-portable shell in the ship/guard scripts.
# Why: ops/ship-kit/pyp-ship.sh line 12 ran a bare `timeout 120 git fetch`; macOS has no
# `timeout`, so the fetch was silently skipped ("command not found", script carried on)
# and the pipeline nearly shipped a STALE ref. Mac ships bash 3.2 + BSD userland.
#
#   scripts/afx-guard/afx-lint-guard-scripts.sh [--warn] [file-or-dir ...]
#   --warn   report findings but exit 0 (default: exit 1 on any finding)
#   --help
# Default targets (relative to the repo root): scripts/afx-guard/*.sh, ops/ship-kit/*.sh,
# scripts/*.sh. Anything missing is skipped.
#
# Rules
#   TIMEOUT   bare `timeout`/`gtimeout` invocation -> use afx_platform_timeout (afx-platform.sh)
#   GNU-ONLY  readlink -f, sed -i (no suffix arg), date -d, stat -c, grep -P, base64 -w,
#             xargs -r, flock, du --exclude, head -n -N
#   BASH4     mapfile/readarray, declare -A, ${var,,} ${var^^}  (macOS bash is 3.2)
# Opt-out where GNU tools are CORRECT (e.g. commands that run on the Linux repl):
#   append `# afx-lint: allow` to the line, or put `# afx-lint: allow-file` anywhere in the file.
# Or list the file in afx-lint-guard-scripts.allow next to this script: `<basename> <RULE[,RULE]>  # why`
# (used for code that only ever runs on the Linux repl inside an ssh heredoc).
# A line that already carries a BSD+GNU fallback (`date -v ... || date -d`) is not flagged.
# Comments, `command -v timeout` probes and afx-platform.sh's own fallback are not flagged.
# Exit: 0 clean (or --warn)  1 findings  2 usage.
set -u
WARN=0; TARGETS=""
for a in "$@"; do
  case "$a" in
    --help|-h) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]:-$0}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    --warn) WARN=1 ;;
    -*) echo "unknown option $a" >&2; exit 2 ;;
    *) TARGETS="$TARGETS
$a" ;;
  esac
done
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -z "$TARGETS" ]; then
  for d in scripts/afx-guard ops/ship-kit scripts; do
    [ -d "$ROOT/$d" ] && TARGETS="$TARGETS
$(ls "$ROOT/$d"/*.sh 2>/dev/null)"
  done
fi
FILES=""
while IFS= read -r t; do
  [ -z "$t" ] && continue
  if [ -d "$t" ]; then FILES="$FILES
$(ls "$t"/*.sh 2>/dev/null)"; elif [ -f "$t" ]; then FILES="$FILES
$t"; fi
done <<EOF
$TARGETS
EOF
FILES="$(printf '%s\n' "$FILES" | sed '/^$/d' | sort -u)"
[ -n "$FILES" ] || { echo "afx-lint-guard-scripts: no scripts found to lint" >&2; exit 2; }

TMP="$(mktemp "${TMPDIR:-/tmp}/afx-lint.XXXXXX")"
N=0; NF=0
while IFS= read -r f; do
  NF=$((NF + 1))
  grep -q 'afx-lint: allow-file' "$f" && continue
  case "$f" in */afx-platform.sh|*/afx-lint-guard-scripts.sh) continue ;; esac
  ALLOW=" $(awk -v b="$(basename "$f")" '$1==b {split($2,a,","); for (i in a) printf "%s ", a[i]}' "$(dirname "${BASH_SOURCE[0]:-$0}")/afx-lint-guard-scripts.allow" 2>/dev/null) "
  awk -v F="$f" -v ALLOW="$ALLOW" '
    function rep(rule, msg) { if (index(ALLOW, " " rule " ")) return; printf "%s:%d: [%s] %s\n    %s\n", F, NR, rule, msg, $0 }
    /afx-lint: allow/ { next }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      # drop a trailing comment and quoted echo text is not stripped (kept simple, may over-flag)
      if (line ~ /command -v (g?timeout)/ || line ~ /afx_platform_timeout/) next
      if (line ~ /(^|[;&|(`{]|\$\(|then|do|else|exec)[[:space:]]*g?timeout[[:space:]]+[0-9-]/ || line ~ /^[[:space:]]*g?timeout[[:space:]]+/)
        rep("TIMEOUT", "bare timeout: not on stock macOS (fails silently, script continues). Use afx_platform_timeout <secs> <cmd> (afx-platform.sh)")
      if (line ~ /readlink -f/) rep("GNU-ONLY", "readlink -f is missing on BSD/macOS; use cd+pwd -P or python")
      if (line ~ /(^|[^a-z])sed -i([[:space:]]+[^'"'"'"[:space:]-]|[[:space:]]*$)/ && line !~ /sed -i[[:space:]]*(\x27\x27|"")/ && line !~ /sed -i\.[a-z]+/)
        rep("GNU-ONLY", "sed -i without a suffix argument differs on BSD sed; write to a temp file and mv")
      if (line ~ /date -v/ || line ~ /stat -f/) next
      if (line ~ /date -d[[:space:]]/) rep("GNU-ONLY", "date -d is GNU; BSD uses date -j -f / -v")
      if (line ~ /stat -c[[:space:]]/) rep("GNU-ONLY", "stat -c is GNU; BSD uses stat -f")
      if (line ~ /grep (-[a-zA-Z]*P|--perl)/) rep("GNU-ONLY", "grep -P is unavailable on stock macOS; use -E or node")
      if (line ~ /base64 -w/) rep("GNU-ONLY", "base64 -w is GNU; pipe through tr -d \"\\n\"")
      if (line ~ /xargs -r/) rep("GNU-ONLY", "xargs -r is GNU; guard for empty input explicitly")
      if (line ~ /(^|[;&|(`[:space:]])flock[[:space:]]/) rep("GNU-ONLY", "flock is not on macOS; use afx-lock.sh")
      if (line ~ /du .*--exclude/) rep("GNU-ONLY", "du --exclude is GNU (BSD: -I)")
      if (line ~ /(^|[;&|[:space:]])(mapfile|readarray)[[:space:]]/) rep("BASH4", "mapfile/readarray need bash 4 (macOS has 3.2)")
      if (line ~ /declare -A/) rep("BASH4", "associative arrays need bash 4 (macOS has 3.2)")
      if (line ~ /\$\{[A-Za-z_0-9]+(,,|\^\^)/) rep("BASH4", "${var,,} / ${var^^} need bash 4; use tr")
    }' "$f" >>"$TMP"
done <<EOF
$FILES
EOF
N="$(grep -c '^[^ ].*: \[' "$TMP" || true)"
cat "$TMP"; rm -f "$TMP"
echo "afx-lint-guard-scripts: scanned $NF script(s), $N finding(s)."
if [ "${N:-0}" -gt 0 ]; then
  [ "$WARN" -eq 1 ] && { echo "(--warn: exit 0)"; exit 0; }
  exit 1
fi
exit 0
