# afx-platform.sh: OS-detection helpers so the rest of afx-guard runs the same
# way on macOS (BSD userland), Linux (Replit repls, GNU userland) and Windows
# (Git Bash / MSYS2, GNU userland). Source it, don't execute it:
#
#   . "$(dirname "$0")/afx-platform.sh"
#
# Design: there are really only two userlands to support, not three.
# Git for Windows' bash ships MSYS2's coreutils, which are the GNU tools
# (GNU sed, GNU stat, GNU md5sum). So every function below branches on
# "Darwin (BSD tools) vs everything else (GNU tools)", and a THIRD, narrower
# branch only where Windows genuinely has no POSIX equivalent at all
# (load average, swap/memory pressure) and has to shell out to PowerShell.
#
# Mac-only steps (xcodebuild, simctl, sips, altool) are NOT made portable here
# on purpose — they are gated with afx_platform_require_mac in the scripts
# that call them, per the task constraint that this is Apple tooling only.
#
# STABLE CONSUMER INTERFACE — AFX_GUARD_DIR: every afx-guard entrypoint that
# sources a sibling script (afx-platform.sh, afx-run.sh) resolves that
# sibling's directory in this order: (1) $AFX_GUARD_DIR if set, (2) the
# directory containing the invoked script itself (`dirname "$0"` /
# `dirname "${BASH_SOURCE[0]}"`). Other repos in the portfolio (e.g.
# afx-local-ai's mac/scripts/*.sh) call these scripts by path from outside
# this repo; today several of them hardcode an absolute path to one
# machine's clone of afx-holding-group. Setting `export AFX_GUARD_DIR=/path/
# to/afx-holding-group/scripts/afx-guard` before calling any afx-guard
# script is the supported way to avoid that hardcoding — it does not change
# any script's own path or CLI/exit-code interface, it only changes where
# that script looks for ITS sibling scripts. Unset, behavior is unchanged
# from before this variable existed (pure backward compatibility).
set -u

afx_platform_os() {
  # Prints: mac | linux | windows
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo mac ;;
    Linux) echo linux ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo unknown ;;
  esac
}

afx_platform_is_bsd() { [ "$(afx_platform_os)" = mac ]; }
afx_platform_is_gnu() { ! afx_platform_is_bsd; }

afx_platform_require_mac() {
  # Call at the top of any script that shells out to xcodebuild/simctl/sips/
  # altool. Prints why and exits 3 on any non-Mac platform.
  local caller="${1:-this step}"
  if [ "$(afx_platform_os)" != mac ]; then
    echo "$caller is Mac-only (Xcode/simctl toolchain); skipping on $(afx_platform_os)" >&2
    return 3
  fi
  return 0
}

afx_platform_ncpu() {
  case "$(afx_platform_os)" in
    mac) sysctl -n hw.ncpu 2>/dev/null ;;
    linux) nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null ;;
    windows)
      # Windows always exports this into every process, Git Bash included.
      if [ -n "${NUMBER_OF_PROCESSORS:-}" ]; then echo "$NUMBER_OF_PROCESSORS"
      else nproc 2>/dev/null || echo 4; fi
      ;;
    *) nproc 2>/dev/null || echo 4 ;;
  esac
}

afx_platform_load1() {
  # Prints a 1-minute load-average-style number. On Windows there is no true
  # loadavg concept (no run-queue-length metric exposed cheaply); this
  # approximates it as (CPU% busy / 100 * ncpu), which is comparable enough
  # for a "is this machine saturated" preflight gate, not bit-for-bit
  # equivalent to POSIX loadavg. Documented as an approximation in the parity
  # matrix — do not use it for anything more precise than a go/no-go gate.
  case "$(afx_platform_os)" in
    mac) sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' ;;
    linux) awk '{print $1}' /proc/loadavg 2>/dev/null || uptime | sed -E 's/.*load average[s]?: ([0-9.]+).*/\1/' ;;
    windows)
      local pct ncpu
      pct=$(powershell.exe -NoProfile -Command \
        "(Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue" 2>/dev/null \
        | tr -d '\r' | head -1)
      ncpu=$(afx_platform_ncpu)
      if [ -n "$pct" ]; then awk -v p="$pct" -v n="$ncpu" 'BEGIN{printf "%.2f", (p/100.0)*n}'
      else echo 0; fi
      ;;
    *) echo 0 ;;
  esac
}

afx_platform_mem_summary() {
  # One-line human-readable memory/swap pressure summary for a preflight log.
  case "$(afx_platform_os)" in
    mac) sysctl vm.swapusage 2>/dev/null | sed 's/^vm\.swapusage: *//' ;;
    linux)
      if command -v free >/dev/null 2>&1; then free -h | awk 'NR==2{print "mem used="$3" free="$4" avail="$7} NR==3{print "swap used="$3" free="$4}'
      else awk '/MemTotal|MemAvailable|SwapTotal|SwapFree/{printf "%s=%dMB ", $1, $2/1024}' /proc/meminfo 2>/dev/null; echo; fi
      ;;
    windows)
      powershell.exe -NoProfile -Command \
        "\$o=Get-CimInstance Win32_OperatingSystem; '{0}={1}MB {2}={3}MB' -f 'freeMB',([math]::Round(\$o.FreePhysicalMemory/1024)),'totalMB',([math]::Round(\$o.TotalVisibleMemorySize/1024))" \
        2>/dev/null | tr -d '\r'
      ;;
    *) echo "unknown" ;;
  esac
}

afx_platform_swap_used_gb() {
  # Prints swap *used* in GB (one decimal), or empty if it cannot be determined.
  # L-001 (2026-09-26 PYP incident): swap thrash after long uptime silently
  # turned every build/sim step into a multi-minute timeout, and looked like a
  # code/network/lock problem until `sysctl vm.swapusage` was checked — by
  # then the Mac needed a restart. This is the machine-readable form of that
  # check, used by afx-preflight.sh to FAIL before a build starts instead of
  # after it has already wedged.
  case "$(afx_platform_os)" in
    mac)
      sysctl vm.swapusage 2>/dev/null | sed -nE 's/.*used = ([0-9.]+)M.*/\1/p' | awk '{printf "%.1f", $1/1024}'
      ;;
    linux)
      if command -v free >/dev/null 2>&1; then
        free -m 2>/dev/null | awk '/^Swap:/{printf "%.1f", $3/1024}'
      else
        awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{if (t>0) printf "%.1f", (t-f)/1024/1024}' /proc/meminfo 2>/dev/null
      fi
      ;;
    windows)
      # No direct swap/pagefile-used counter cheaply available via CIM without
      # extra permissions; approximate as (committed - physical used) is not
      # reliable enough for a gate, so this is left unmeasured on Windows —
      # documented gap in AFX_PLATFORM_PARITY.md, not silently wrong.
      echo ""
      ;;
    *) echo "" ;;
  esac
}

afx_platform_disk_free_gb() {
  # afx_platform_disk_free_gb <path>
  local p="${1:-.}"
  case "$(afx_platform_os)" in
    mac) df -g "$p" 2>/dev/null | awk 'NR==2{print $4}' ;;
    linux|windows) df -BG "$p" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}' ;;
    *) df -k "$p" 2>/dev/null | awk 'NR==2{printf "%d", $4/1024/1024}' ;;
  esac
}

afx_platform_home_quota_gb() {
  # Linux-only: a Replit repl's `df` reports the container's overlay filesystem
  # (tens of GB free), but $HOME sits on a much smaller, separately-quota'd
  # volume (~5 GB in practice) that `df` does not reflect at all — a repl can
  # show "28GB free" from afx_platform_disk_free_gb and still hit EDQUOT
  # writing to $HOME. Confirmed 2026-09-27: HTR's repl hit EDQUOT (even under
  # /tmp, which is also inside the quota'd volume there) from two concurrent
  # agent E2E checkouts, fixed by afx-remote-gate.sh's flock serialization
  # (#198) and shared --store-dir (#199). This is a real `du` walk of $HOME
  # (excluding ~/workspace, which is the one large, legitimately-necessary
  # directory), so it costs real time on a large home — call it in preflight,
  # not in a hot loop.
  du -sm --exclude=workspace "$HOME" 2>/dev/null | awk '{printf "%.2f", $1/1024}'
}

afx_platform_md5() {
  # afx_platform_md5 <file> -> prints the hex digest only (no filename).
  local f="$1"
  if command -v md5sum >/dev/null 2>&1; then md5sum "$f" 2>/dev/null | awk '{print $1}'
  elif command -v md5 >/dev/null 2>&1; then md5 -q "$f" 2>/dev/null
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -md5 "$f" 2>/dev/null | awk '{print $NF}'
  else echo "NO_MD5_TOOL" >&2; return 1; fi
}

afx_platform_sed_inplace() {
  # afx_platform_sed_inplace 's/foo/bar/' file [file...]
  # GNU sed (Linux, and Windows Git Bash via MSYS2 coreutils) takes -i with
  # no argument for "no backup". BSD sed (macOS) requires -i '' (a mandatory,
  # even if empty, backup-suffix argument).
  local script="$1"; shift
  if afx_platform_is_bsd; then
    sed -i '' -e "$script" "$@"
  else
    sed -i -e "$script" "$@"
  fi
}

afx_platform_stat_mtime() {
  # afx_platform_stat_mtime <file> -> epoch seconds of last modification.
  local f="$1"
  if afx_platform_is_bsd; then stat -f %m "$f" 2>/dev/null
  else stat -c %Y "$f" 2>/dev/null; fi
}

afx_platform_date_to_epoch() {
  # afx_platform_date_to_epoch <UTC ISO 8601, e.g. 2026-09-27T11:00:00Z>
  # BSD date (macOS) needs -j -f with an explicit strptime format; GNU date
  # (Linux, Windows/Git-Bash) parses ISO 8601 directly with -d.
  local iso="$1"
  if afx_platform_is_bsd; then
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null
  else
    date -u -d "$iso" +%s 2>/dev/null
  fi
}

afx_platform_trash_cmd() {
  # afx_platform_trash_cmd <folder> <repo-main-checkout> [merged-tip-commit...]
  # Prints the ONE-LINE command that disposes of a leftover worktree folder that `git worktree remove` could not delete ("Directory not
  # empty", "Permission denied", a pnpm hardlink tree): move it to the Trash (never rm -rf, per the owner rule) then prune git's records.
  # Run it only after confirming the branch tip is on GitHub (afx-land.sh --cleanup already did).
  local d="$1" r="$2" guard tips=""
  [ $# -ge 3 ] && { shift 2; tips="$(printf '%s,' "$@")"; tips="${tips%,}"; }
  guard="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
  [ -n "$guard" ] || guard="$HOME/.afx/afx-guard"
  case "$(afx_platform_os)" in
    mac) printf "osascript -e 'tell application \"Finder\" to delete POSIX file \"%s\"' && git -C \"%s\" worktree prune\n" "$d" "$r" ;;
    windows) if command -v cygpath >/dev/null 2>&1; then guard="$(cygpath -m "$guard")"; r="$(cygpath -m "$r")"; d="$(cygpath -m "$d")"; fi
             printf 'powershell -NoProfile -ExecutionPolicy Bypass -File "%s/windows/afx-worktree-remove.ps1" -RepoPath "%s" -WorktreePath "%s"%s\n' "$guard" "$r" "$d" "${tips:+ -TipCommit $tips}" ;;
    *) printf 'gio trash "%s" && git -C "%s" worktree prune\n' "$d" "$r" ;;
  esac
}

afx_platform_timeout() {
  # afx_platform_timeout <seconds> <command...>
  # Prefers a real `timeout` (GNU coreutils: stock on Linux; on macOS only if
  # `coreutils` is brew-installed; on Windows Git Bash it is NOT bundled by
  # default). Falls back to `gtimeout` (Homebrew's prefixed name), then to a
  # pure-bash background+kill implementation so this never hard-depends on an
  # external binary that might be missing on a given machine.
  local secs="$1"; shift
  # type -P (executables only): a caller may define a `timeout` shell function that points back here
  if type -P timeout >/dev/null 2>&1; then
    command timeout "$secs" "$@"
    return $?
  elif type -P gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
    return $?
  fi
  # Pure fallback (no timeout/gtimeout binary). CRITICAL: must preserve stdin.
  # Callers pipe a heredoc into `ssh bash -s`; a backgrounded command in
  # non-interactive bash has its stdin silently redirected from /dev/null, so the
  # old `"$@" &` made afx-remote-gate.sh reach ssh with an EMPTY script and exit 0
  # with no output — the 2026-09-30 "gate runs 40+ min, no result" incident.
  # Prefer perl: it forks so the child inherits our stdin via exec, while the
  # parent enforces the timeout (124 on timeout, like GNU timeout).
  if command -v perl >/dev/null 2>&1; then
    perl -e '
      my $s = shift @ARGV;
      my $pid = fork();
      die "afx_timeout fork: $!\n" unless defined $pid;
      if ($pid == 0) { exec { $ARGV[0] } @ARGV or exit 127; }
      my $timed_out = 0;
      local $SIG{ALRM} = sub { $timed_out = 1; kill "TERM", $pid; };
      alarm $s;
      waitpid($pid, 0);
      my $st = $?;
      exit 124 if $timed_out;
      exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
    ' "$secs" "$@"
    return $?
  fi
  # Last-resort bash fallback: keep stdin with <&0 so the heredoc still reaches
  # the command even though it is backgrounded for the timeout.
  "$@" <&0 &
  local cmd_pid=$!
  ( sleep "$secs" && kill -TERM "$cmd_pid" 2>/dev/null ) &
  local watcher_pid=$!
  local rc
  wait "$cmd_pid" 2>/dev/null
  rc=$?
  kill "$watcher_pid" 2>/dev/null
  wait "$watcher_pid" 2>/dev/null
  return "$rc"
}

# afx_config_get <key>: one configuration value (org, hubRepo, extraOrgs, clonesRootMac, clonesRootWindows, registryFile, brand,
# quickstartDoc, enabledModules, policyPacks). Order: $AFX_CONFIG, then ~/.afx/afx.config.json (read by afx-config.mjs, needs
# node), else the built-ins from afx-config-defaults.sh (no node needed): neutral, or the tenant preset
# afx-config-defaults.afx.sh when that private file sits next to it. Paths come back with a leading "~"; expand
# with ${v/#\~/$HOME}. Prints nothing and returns 1 for an unknown key. Schema: afx.config.schema.json.
_AFX_PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
[ -f "$_AFX_PLATFORM_DIR/afx-config-defaults.sh" ] && . "$_AFX_PLATFORM_DIR/afx-config-defaults.sh"
afx_config_get() {
  local key="$1" f="${AFX_CONFIG:-$HOME/.afx/afx.config.json}" js v
  js="$_AFX_PLATFORM_DIR/afx-config.mjs"
  if [ -f "$f" ] && [ -f "$js" ] && command -v node >/dev/null 2>&1; then
    js=$(cygpath -m "$js" 2>/dev/null || echo "$js")
    if v=$(node "$js" get "$key" 2>/dev/null); then echo "$v"; return 0; fi
  fi
  if type _afx_config_default >/dev/null 2>&1; then _afx_config_default "$key"; else return 1; fi
}

# afx_owner_regex: ERE that matches a git remote URL owned by the configured org (config keys org + extraOrgs); never matches
# when none is configured. Callers let AFX_GH_OWNERS override it.
afx_owner_regex() {
  local list x
  list=$(afx_config_get org)
  for x in $(afx_config_get extraOrgs); do list="${list:+$list|}$x"; done
  if [ -n "$list" ]; then echo "[:/]($list)/"; else echo "a^"; fi
}

afx_platform_clones_root() {
  # Best-effort default root for the "all venture clones" directory, used by
  # preflight/fragment-audit/preserve-all when no root is passed explicitly.
  # Only meaningful on the Mac coordinator today; other platforms should pass
  # an explicit root and this is just a sane fallback so a bare invocation
  # doesn't crash with an empty path.
  local _acr
  case "$(afx_platform_os)" in
    mac) _acr=$(afx_config_get clonesRootMac); echo "${_acr/#\~/$HOME}" ;;
    linux) echo "$HOME/workspace" ;;
    windows) echo "${AFX_CLONES_ROOT:-$HOME/Projects}" ;;
    *) echo "$HOME" ;;
  esac
}

afx_platform_set_aside_dest() {
  # afx_platform_set_aside_dest <worktree>
  # Prints the folder where things from a worktree that is about to be removed are kept: <root>/<date>/<repo>/<worktree-name>.
  # Root is $AFX_SET_ASIDE_DIR, default ~/.afx/set-aside (outside every clone, never in git, never emptied by an agent).
  local wt="$1" common repo
  common=$(cd "$wt" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd) || common=""
  repo=$(basename "$(dirname "${common:-$wt}")")
  printf '%s/%s/%s/%s\n' "${AFX_SET_ASIDE_DIR:-$HOME/.afx/set-aside}" "$(date +%Y-%m-%d)" "$repo" "$(basename "$wt")"
}

afx_platform_set_aside_secrets() {
  # afx_platform_set_aside_secrets <worktree>
  # `git worktree remove` deletes gitignored files without a word, and a clean `git status` does not show them. On 2026-10-13 an
  # untracked .env.production went that way with no copy. Before a worktree is removed, copy every gitignored or untracked env/key
  # file (.env, .env.*, *.p8, *.pem, *.jks, *.keystore, *.mobileprovision; not *.example/*.sample/*.template/*.dist) to the set-aside
  # folder, mode 600. Prints one line when it kept something. Returns 1 if a file could not be copied (the caller must then not remove).
  local wt="$1" dest n=0 f rel
  dest="$(afx_platform_set_aside_dest "$wt")/secrets"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in */) continue;; esac
    case "$(basename "$rel")" in
      *.example|*.sample|*.template|*.dist) continue;;
      .env|.env.*|*.p8|*.pem|*.jks|*.keystore|*.mobileprovision) ;;
      *) continue;;
    esac
    f="$wt/$rel"; [ -f "$f" ] || continue
    mkdir -p "$dest/$(dirname "$rel")" && cp -p "$f" "$dest/$rel" && chmod 600 "$dest/$rel" || { echo "afx-platform: could not set aside $f" >&2; return 1; }
    n=$((n+1))
  done <<AFX_SA_EOF
$( { git -C "$wt" ls-files --others --exclude-standard --directory; git -C "$wt" ls-files --others --ignored --exclude-standard --directory; } 2>/dev/null | sort -u)
AFX_SA_EOF
  [ "$n" -gt 0 ] && echo "set aside $n env/key file(s) from $(basename "$wt") in $dest (mode 600)"
  return 0
}

# ---- Posture (owner directive 2026-10-21: zero users, so monitors must not wake paid Replit apps) ----
# afx_posture_resolve: prints "<value> <source>" where source is env | machine.conf | default.
# Order: env AFX_POSTURE, else the `posture=` line of machine.conf (read like `root=` in afx-sweep.sh; AFX_MACHINE_CONF overrides the
# path for tests), else parked. Only the literal value `live` is live; unset or anything else is PARKED.
afx_posture_resolve() {
  local v="" src=default conf="${AFX_MACHINE_CONF:-$HOME/.claude/hooks/afx-guard/machine.conf}"
  if [ -n "${AFX_POSTURE:-}" ]; then v="$AFX_POSTURE"; src=env
  else
    v=$(sed -n 's/^posture=//p' "$conf" 2>/dev/null | head -1 | tr -d '\r')
    [ -n "$v" ] && src=machine.conf
  fi
  [ "$v" = live ] || v=parked
  printf '%s %s\n' "$v" "$src"
}
# afx_posture_parked: returns 0 (true) when parked, 1 when live.
afx_posture_parked() { [ "$(afx_posture_resolve | cut -d' ' -f1)" != live ]; }
# afx_posture_gate <script-name> <force 0|1>: call at the top of a fleet monitor. Returns 0 to carry on, 1 after printing the single
# skip line (the caller then does `exit 0`). A manual --force run (force=1) always proceeds.
afx_posture_gate() {
  [ "${2:-0}" = 1 ] && return 0
  afx_posture_parked || return 0
  echo "$1: parked: skipped (set posture=live in machine.conf or AFX_POSTURE=live to run)"
  return 1
}
