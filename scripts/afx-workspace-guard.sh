# afx-workspace-guard.sh: source this from any script that runs (or may run)
# on a Replit repl and creates scratch checkouts, E2E worktrees, or gate
# directories. Provides afx_refuse_workspace, which refuses loudly and
# returns non-zero if the current directory (or a path you pass it) is
# $HOME/workspace itself, or anything under it.
#
#   . "$(dirname "$0")/afx-workspace-guard.sh"
#   afx_refuse_workspace || exit 1            # checks $PWD
#   afx_refuse_workspace "$SOME_TARGET_DIR"   # checks an explicit path instead
#
# L-015 / A-OPS-1 (2026-09-26, HTR): a gate agent worked around a
# cross-filesystem pnpm error by cloning a scratch checkout
# (.gate-scratch-pr127, 4.3 GB) INSIDE the repl's ~/workspace. The Replit
# Agent — a separate, autonomous actor that also pushes to this same repo
# (see L-012) — then committed it to main (13,664 files, one commit), which
# left a self-referencing node_modules/node_modules symlink that broke
# publish with ELOOP. ~/workspace is Replit's own git checkout; anything left
# there can be picked up and committed by that other actor, or can corrupt
# its own working tree. AGENT_RULES states this in prose ("NEVER create or
# edit anything inside ~/workspace on any repl"); this file is the
# machine-checkable form of that rule.
#
# Deliberately does NOT special-case "read-only" access — even a read that
# happens to `cd` into ~/workspace and then runs something that shells out to
# a mutating command (git, pnpm, rm) is exactly the failure mode this guards
# against, so the check is on cwd/path alone, not on declared intent.
set -u

afx_refuse_workspace() {
  local target="${1:-$PWD}"
  local resolved
  # Resolve symlinks / relative paths where possible; fall back to the raw
  # string if the path doesn't exist yet (e.g. checking a not-yet-created
  # target directory before creating it).
  resolved="$(cd "$target" 2>/dev/null && pwd -P)"
  [ -z "$resolved" ] && resolved="$target"
  case "$resolved" in
    "$HOME/workspace"|"$HOME/workspace/"*)
      echo "" >&2
      echo "REFUSED (L-015 / A-OPS-1): '$resolved' is inside \$HOME/workspace." >&2
      echo "  ~/workspace is a Replit repl's own git checkout. A separate, autonomous" >&2
      echo "  Replit Agent (L-012) can commit anything left there, and a stray checkout" >&2
      echo "  there has broken a live deploy before (HTR, 2026-09-26)." >&2
      echo "  Never create, edit, or change into anything under ~/workspace." >&2
      echo "  Use a worktree OUTSIDE it instead: ~/e2e-<name> for E2E work, or" >&2
      echo "  ~/gate-<branch> (see afx-remote-gate.sh) for gate runs." >&2
      echo "" >&2
      return 1
      ;;
  esac
  return 0
}

# afx_cd_or_refuse <dir>: the "cd ... || exit" + workspace-guard combined in
# one call, for scripts that want a single line covering both R-rules (never
# a bare cd; never into ~/workspace). Changes the CALLER's directory (this
# must be called directly, not in a subshell/pipeline) — mirrors plain `cd`
# semantics on purpose so `afx_cd_or_refuse "$W" || exit 1` reads the same as
# `cd "$W" || exit 1`.
afx_cd_or_refuse() {
  local dir="$1"
  afx_refuse_workspace "$dir" || return 1
  cd "$dir" || { echo "REFUSED: cd '$dir' failed (directory missing or unreadable) — refusing to continue in an unknown cwd." >&2; return 1; }
}
