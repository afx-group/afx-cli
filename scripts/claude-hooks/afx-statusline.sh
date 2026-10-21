#!/bin/bash
# afx-statusline.sh: Claude Code status line for AFX machines (installed by afx-install-claude-hooks.sh).
# One line: machine · location class · repo@branch (+dirty) · freeze · free disk · model.
# Must stay fast (runs on every refresh): no network, no git fetch.
input=$(cat)
G="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cwd=$(printf '%s' "$input" | sed -n 's/.*"current_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -z "$cwd" ] && cwd=$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -z "$cwd" ] && cwd="$PWD"
model=$(printf '%s' "$input" | sed -n 's/.*"display_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
machine=$(sed -n 's/^machine=//p' "$G/machine.conf" 2>/dev/null | cut -c1-24)
class=$(AFX_STALE_TIERS="999 999 999" "$G/afx-where-am-i.sh" "$cwd" 2>/dev/null | cut -d' ' -f1)
repo=""; top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
if [ -n "$top" ]; then
  br=$(git -C "$cwd" branch --show-current 2>/dev/null)
  d=$(git -C "$cwd" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  name=$(echo "$top" | sed -n 's#.*/_clones/\([^/]*\).*#\1#p'); [ -z "$name" ] && name=$(basename "$top")
  repo="$name@${br:-detached}"; [ "$d" != 0 ] && repo="$repo +$d"
fi
_cr="${AFX_CLONES_ROOT:-}"
if [ -z "$_cr" ] && [ -f "$G/afx-platform.sh" ]; then . "$G/afx-platform.sh" 2>/dev/null; _cr=$(afx_config_get clonesRootMac 2>/dev/null); _cr="${_cr/#\~/$HOME}"; fi
F="$_cr/.caches/afx-freeze"
fz=""; [ -f "$F" ] && fz="FREEZE($(sed -n 's/^allow:[[:space:]]*//p' "$F"))"
free=$(df -g "$HOME" 2>/dev/null | awk 'NR==2{print $4"G free"}')
sw=""; grep -q '^BLIND' "$G/sweep-status" 2>/dev/null && sw="SWEEP BLIND"
out=""
for part in "${machine:-afx}" "$class" "$repo" "$fz" "$sw" "$free" "$model"; do [ -n "$part" ] && out="${out:+$out · }$part"; done
printf '%s' "$out"
# --- usage capture (additive, best-effort): snapshot rate_limits for afx-token-kpis.sh -> usage-latest.json.
# Runs AFTER the line is printed; any failure/absence is swallowed and cannot affect the output above.
# Only when the payload carries rate_limits (Pro/Max); writes only when the values changed. No network.
case "$input" in *rate_limits*)
  (
    flat=$(printf '%s' "$input" | tr '\n' ' ')
    rl() { # $1 window, $2 field -> number or null
      v=$(printf '%s' "$flat" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' | head -1 \
          | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -1)
      printf '%s' "${v:-null}"
    }
    core="{\"weeklyUsedPct\":$(rl seven_day used_percentage),\"weeklyResetsAt\":$(rl seven_day resets_at),\"fiveHourUsedPct\":$(rl five_hour used_percentage),\"fiveHourResetsAt\":$(rl five_hour resets_at),"
    case "$core" in *'"weeklyUsedPct":null,"weeklyResetsAt":null,"fiveHourUsedPct":null,"fiveHourResetsAt":null,'*) exit 0;; esac
    old=$(cat "$G/usage-latest.json" 2>/dev/null)
    case "$old" in "$core"*) exit 0;; esac
    printf '%s"capturedAt":%s}\n' "$core" "$(date +%s)" > "$G/usage-latest.json.$$" && mv -f "$G/usage-latest.json.$$" "$G/usage-latest.json"
  ) >/dev/null 2>&1 || :
;; esac
exit 0
