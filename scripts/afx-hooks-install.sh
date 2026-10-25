#!/bin/bash
# afx-hooks-install.sh: install the portfolio-wide afx-guard git hooks
# (pre-commit, pre-push, post-checkout, post-merge — see scripts/afx-guard/
# githooks/) into a target repo's .githooks/ and wire them up via
# `git config core.hooksPath .githooks`. Same enforced checks everywhere:
# L-010/L-011 destructive-staged-path guard + large-commit warning
# (pre-commit); L-012 fetch-before-push + force-push protection on
# main/staging (pre-push); LFS/trunk-sync passthrough (post-checkout,
# post-merge). Local gates only — this portfolio does not use
# .github/workflows.
#
#   scripts/afx-guard/afx-hooks-install.sh [<target-repo-root>]
#     (default target: the repo this script itself lives in)
#   scripts/afx-guard/afx-hooks-install.sh --fleet [<clones-root>]
#     every AFX-owned clone directly under the root (third-party clones such as ComfyUI are skipped). In a clone that
#     already tracks .githooks/ this only sets core.hooksPath, the per-machine step git cannot carry in the repo.
#
# Idempotent: safe to re-run any time the templates change (e.g. after
# pulling a hub update) to refresh an already-installed repo. Never
# overwrites a target repo's OWN pre-existing .githooks/<hook> unless it is
# byte-identical to a PREVIOUS afx-guard template or missing — an existing,
# different hook (e.g. a project's git-lfs-installed hooks) is left in
# place and reported, not clobbered, so a repo-specific hook is never
# silently destroyed.
set -u
DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "$0")" && pwd)}"
. "$DIR/afx-platform.sh"
if [ "${1:-}" = "--fleet" ]; then
  FROOT="${2:-$(afx_platform_clones_root)}"; OWN="${AFX_GH_OWNERS:-$(afx_owner_regex)}"; frc=0
  for d in "$FROOT"/*/; do
    [ -d "$d.git" ] || continue
    if ! git -C "$d" remote get-url origin 2>/dev/null | grep -qiE "$OWN"; then echo "afx-hooks-install: SKIPPED $(basename "$d") (third-party origin)"; continue; fi
    "$0" "${d%/}" | tail -2 || frc=1
  done
  exit $frc
fi
SRC="$DIR/githooks"
TARGET="${1:-$(cd "$DIR/../.." && pwd)}"

[ -d "$SRC" ] || { echo "afx-hooks-install: template dir not found: $SRC" >&2; exit 2; }
git -C "$TARGET" rev-parse --show-toplevel >/dev/null 2>&1 || { echo "afx-hooks-install: not a git repo: $TARGET" >&2; exit 2; }
TARGET="$(git -C "$TARGET" rev-parse --show-toplevel)"

DEST="$TARGET/.githooks"
mkdir -p "$DEST"

MARKER="# afx-guard portable git hooks"
INSTALLED=0; SKIPPED=0
for f in pre-commit pre-push post-checkout post-merge; do
  [ -f "$SRC/$f" ] || continue
  if [ -f "$DEST/$f" ] && ! head -3 "$DEST/$f" 2>/dev/null | grep -qF "$MARKER"; then
    echo "afx-hooks-install: SKIPPED $DEST/$f — exists and is not an afx-guard template (repo-specific hook kept as-is)."
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  cp "$SRC/$f" "$DEST/$f"
  chmod +x "$DEST/$f"
  echo "afx-hooks-install: installed $DEST/$f"
  INSTALLED=$((INSTALLED + 1))
done

git -C "$TARGET" config core.hooksPath .githooks
echo "afx-hooks-install: core.hooksPath = $(git -C "$TARGET" config core.hooksPath) in $TARGET"
echo "afx-hooks-install: $INSTALLED installed/refreshed, $SKIPPED left alone (pre-existing non-afx-guard hook)."
[ "$SKIPPED" -gt 0 ] && echo "afx-hooks-install: review the skipped file(s) above — chain into them from the afx-guard template if this repo needs both (see pre-push's git-lfs passthrough for the pattern)."
exit 0
