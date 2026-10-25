#!/bin/bash
# afx-vendored-drift-lint.sh (sync-guard c): detect a venture's vendored afx-guard scripts
# drifting from the hub's canonical copy. Each venture carries its own copy of the shared guard
# scripts under scripts/afx-guard/; when the hub's versions move and a venture's don't (or a
# venture hand-edits its copy), the fleet's rules silently diverge. This compares every guard
# script a venture shares with the hub, by CONTENT HASH, against the hub's origin/main — using
# the local remote-tracking ref only, no network.
#
#   scripts/afx-guard/afx-vendored-drift-lint.sh [venture-repo-root] [--hub <hub-root>] [--selftest]
#
# Default venture root: the current repo. Hub: $AFX_HUB, else --hub, else the sibling
# <_clones>/afx-hub (formerly afx-holding-group) found by walking up from the venture root. Only files present in
# BOTH the venture and the hub's origin/main tree are compared (venture-specific scripts and
# hub-only scripts are reported as context, never as drift). When run against the hub itself it
# self-skips (the hub is the source of truth). No hub found -> skip (not a failure).
#
# Exit 0: no drift (or nothing to compare / skipped). Exit 1: at least one vendored file differs.
set -u

# Portable content hash of stdin.
hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}';
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}';
  else cksum | awk '{print $1"-"$2}'; fi
}

drift_lint() {
  local VEN_IN="$1" HUB="$2" drift=0 compared=0 only_ven=0 only_hub=0 VEN
  # Normalize to the git worktree root: callers (afx-guard-lint via the pre-commit hook) may
  # pass scripts/afx-guard rather than the repo root. --show-toplevel maps either to the root;
  # a non-git path (e.g. the self-test) falls back to the raw dir.
  VEN="$(git -C "$VEN_IN" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$VEN" ] || VEN="$(cd "$VEN_IN" 2>/dev/null && pwd)"
  [ -n "$VEN" ] || { echo "vendored-drift: venture root not found"; return 0; }
  if [ -z "$HUB" ] || [ ! -d "$HUB" ]; then
    echo "vendored-drift: skipped (no hub checkout found; set \$AFX_HUB or pass --hub). No network lookups done."
    return 0
  fi
  HUB="$(cd "$HUB" 2>/dev/null && pwd -P)"   # -P: the hub folder is afx-hub with an afx-holding-group link beside it (2026-10-13)
  # Resolve the venture to its MAIN worktree root so a hub *worktree*
  # (…/afx-holding-group/.claude/worktrees/x) is still recognised as the hub and self-skips,
  # instead of diffing its own in-progress edits against origin/main. git-common-dir is
  # <mainroot>/.git for both the main checkout and any of its worktrees.
  local ven_main; ven_main="$(git -C "$VEN" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -n "$ven_main" ]; then ven_main="$(cd "$(dirname "$ven_main")" 2>/dev/null && pwd -P)"; else ven_main="$VEN"; fi
  if [ "$VEN" = "$HUB" ] || [ "$ven_main" = "$HUB" ]; then
    echo "vendored-drift: skipped ($(basename "$ven_main") is the hub — the source of truth, nothing to compare)."
    return 0
  fi
  if ! git -C "$HUB" rev-parse --verify -q origin/main >/dev/null 2>&1; then
    echo "vendored-drift: skipped (hub has no origin/main ref; fetch the hub once). No network lookups done."
    return 0
  fi
  # Hub's shipped guard files (origin/main), as a newline list of basenames.
  local hub_list; hub_list="$(git -C "$HUB" ls-tree -r --name-only origin/main scripts/afx-guard 2>/dev/null | grep -E '/[^/]+\.(sh|mjs|py)$')"
  [ -n "$hub_list" ] || { echo "vendored-drift: hub origin/main has no scripts/afx-guard files to compare."; return 0; }

  local vf rel base hubhash venhash
  for vf in "$VEN"/scripts/afx-guard/*.sh "$VEN"/scripts/afx-guard/*.mjs "$VEN"/scripts/afx-guard/claude-hooks/*.mjs; do
    [ -f "$vf" ] || continue
    rel="scripts/afx-guard/${vf#"$VEN"/scripts/afx-guard/}"
    # match against the hub path of the same relative location
    if printf '%s\n' "$hub_list" | grep -qxF "$rel"; then
      hubhash="$(git -C "$HUB" show "origin/main:$rel" 2>/dev/null | hash_stdin)"
      venhash="$(hash_stdin < "$vf")"
      compared=$((compared+1))
      if [ "$hubhash" != "$venhash" ]; then
        echo "  DRIFT: $rel differs from hub origin/main"
        drift=$((drift+1))
      fi
    else
      only_ven=$((only_ven+1))
    fi
  done
  # hub files the venture is missing entirely (context only)
  local hf
  while IFS= read -r hf; do
    [ -n "$hf" ] || continue
    [ -f "$VEN/$hf" ] || only_hub=$((only_hub+1))
  done <<EOF
$hub_list
EOF

  echo "vendored-drift: compared $compared shared file(s); $drift drifted; $only_ven venture-only; $only_hub hub-only (not vendored here)."
  if [ "$drift" -gt 0 ]; then
    echo "  Re-vendor from the hub: copy the hub's scripts/afx-guard/<file> over the venture's, or run the sync PR. (Advisory: a venture may intentionally pin an older guard — confirm before overwriting.)"
    return 1
  fi
  return 0
}

# ── self-test (builds throwaway git repos under mktemp; real exit codes) ─────
selftest() {
  local T; T=$(mktemp -d); local overall=0 rc
  local hub="$T/afx-holding-group" ven="$T/venture"
  git init -q "$hub"; mkdir -p "$hub/scripts/afx-guard"
  printf 'echo shared-A\n' > "$hub/scripts/afx-guard/afx-shared.sh"
  printf 'echo shared-B\n' > "$hub/scripts/afx-guard/afx-other.sh"
  git -C "$hub" add -A >/dev/null 2>&1
  git -C "$hub" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
  git -C "$hub" update-ref refs/remotes/origin/main HEAD   # simulate a fetched origin/main, no network

  mkdir -p "$ven/scripts/afx-guard"
  cp "$hub/scripts/afx-guard/afx-shared.sh" "$ven/scripts/afx-guard/afx-shared.sh"   # identical
  cp "$hub/scripts/afx-guard/afx-other.sh"  "$ven/scripts/afx-guard/afx-other.sh"    # identical
  printf 'echo venture-only\n' > "$ven/scripts/afx-guard/afx-venture-only.sh"        # venture-specific

  drift_lint "$ven" "$hub" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && echo "  selftest clean(no drift): PASS (rc=0)" || { echo "  selftest clean: FAIL (rc=$rc)"; overall=1; }

  printf 'echo shared-A-EDITED\n' > "$ven/scripts/afx-guard/afx-shared.sh"           # introduce drift
  drift_lint "$ven" "$hub" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && echo "  selftest drift(edited vendored): PASS (rc=1)" || { echo "  selftest drift: FAIL (rc=$rc, expected 1)"; overall=1; }

  drift_lint "$hub" "$hub" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && echo "  selftest hub-self-skip: PASS (rc=0)" || { echo "  selftest hub-self-skip: FAIL (rc=$rc)"; overall=1; }

  drift_lint "$ven" "$T/nope" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && echo "  selftest no-hub-skip: PASS (rc=0)" || { echo "  selftest no-hub-skip: FAIL (rc=$rc)"; overall=1; }

  rm -rf "$T"
  [ "$overall" -eq 0 ] && echo "SELFTEST: all cases PASS" || echo "SELFTEST: FAILURES above"
  return $overall
}

# ── args ─────────────────────────────────────────────────────────────────────
VEN_ROOT=""; HUB_ROOT="${AFX_HUB:-}"
while [ $# -gt 0 ]; do case "$1" in
  --hub) HUB_ROOT="$2"; shift 2;;
  --selftest) selftest; exit $?;;
  -h|--help) sed -n '2,20p' "$0"; exit 0;;
  -*) echo "unknown flag: $1" >&2; exit 2;;
  *) VEN_ROOT="$1"; shift;;
esac; done

[ -n "$VEN_ROOT" ] || VEN_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Locate the hub if not supplied: walk up to a _clones dir, then _clones/afx-holding-group.
if [ -z "$HUB_ROOT" ]; then
  d="$(cd "$VEN_ROOT" 2>/dev/null && pwd)"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ "$(basename "$d")" = "_clones" ]; then
      if [ -d "$d/afx-hub" ]; then HUB_ROOT="$d/afx-hub"; break; elif [ -d "$d/afx-holding-group" ]; then HUB_ROOT="$d/afx-holding-group"; break; fi
    fi
    d="$(dirname "$d")"
  done
fi

drift_lint "$VEN_ROOT" "$HUB_ROOT"
exit $?
