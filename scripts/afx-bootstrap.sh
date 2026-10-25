#!/bin/bash
# afx-bootstrap.sh: give a fresh machine (Linux VM, cloud shell, Mac, Windows Git Bash) the AFX terminal-agent
# tooling, so it can replicate the same process as the owner's machines.
#
# PRIVATE BY CONSTRUCTION. Nothing is published anywhere. Everything is fetched from your private hub
# GitHub repo with the CALLER'S OWN GitHub credentials (gh). No token, key, customer data or internal URL is
# embedded here. If the caller cannot read the hub repo this script stops: that is the access
# control. (Paid-customer distribution is a separate, later channel: ops/AFX_MACHINE_BOOTSTRAP.md.)
#
#   afx-bootstrap.sh --check                 read-only: report prerequisites and access, change nothing
#   afx-bootstrap.sh [--dest DIR] [--ref REF] [--no-registry]
#       --dest DIR      tooling home (default ~/.afx)
#       --ref REF       branch/tag/commit of the hub to export (default main); pin a SHA for reproducibility
#       --no-registry   do not create a registry stub
#
# What it does (idempotent, never overwrites a file you already have):
#   1. checks git, gh, python3, and that gh is signed in with read access to the hub repo
#   2. sparse-fetches ONLY scripts/afx-guard from the hub into DEST/src (a tooling cache, not a project clone)
#   3. exports it to DEST/afx-guard and records the commit in DEST/afx-guard/.exported-from-sha
#   4. installs the launcher and the short `afx` command to DEST/bin and prints the PATH line
#   5. creates DEST/afx-projects.json from the example if you have no registry (fill in real paths)
# It does NOT clone any project, install hooks, write secrets, or change shell profiles.
set -u
DEST="${AFX_HOME:-$HOME/.afx}"; REF="main"; CHECK=0; REGISTRY=1
# The hub repo was renamed afx-holding-group -> afx-hub (2026-10-14); GitHub redirects the old name, so either works.
# Order: $AFX_HUB_SLUG, then hubRepo in $AFX_CONFIG / ~/.afx/afx.config.json (read with sed: nothing is fetched yet, so no
# helper script exists), then the AFX preset (afx-config.afx.json next to this script, private tier; present when you run this
# from the hub itself), else no hub is known and the script stops with a message.
_cfg="${AFX_CONFIG:-$HOME/.afx/afx.config.json}"
_cfg_hub=$(sed -n 's/^[[:space:]]*"hubRepo"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_cfg" 2>/dev/null | head -1)
_preset="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/afx-config.afx.json"
_preset_hub=$(sed -n 's/^[[:space:]]*"hubRepo"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_preset" 2>/dev/null | head -1)
HUB_SLUG="${AFX_HUB_SLUG:-${_cfg_hub:-$_preset_hub}}"
if [ -z "$HUB_SLUG" ]; then echo "afx-bootstrap: no hub repo known. Set AFX_HUB_SLUG=owner/repo, or hubRepo in ~/.afx/afx.config.json (afx init --hub-repo owner/repo)." >&2; exit 64; fi
while [ $# -gt 0 ]; do case "$1" in
  --check) CHECK=1; shift ;;
  --dest) DEST="$2"; shift 2 ;;
  --ref) REF="$2"; shift 2 ;;
  --no-registry) REGISTRY=0; shift ;;
  -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "afx-bootstrap: unknown argument $1" >&2; exit 64 ;;
esac; done

ok()   { echo "  ok    $*"; }
need() { echo "  NEED  $*"; MISSING=$((MISSING+1)); }
did()  { echo "  DID   $*"; }
MISSING=0

echo "1. prerequisites"
for t in git gh python3; do command -v "$t" >/dev/null 2>&1 && ok "$t" || need "$t (install it, then re-run)"; done
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then ok "gh signed in"; else need "gh auth login (use an account that can read $HUB_SLUG)"; fi
  if gh api "repos/$HUB_SLUG" --jq .full_name >/dev/null 2>&1; then ok "read access to $HUB_SLUG"
  else need "read access to $HUB_SLUG: this tooling is internal-only; ask the owner for org access"; fi
fi
if [ "$MISSING" -gt 0 ]; then echo; echo "afx-bootstrap: $MISSING prerequisite(s) missing; nothing was changed."; exit 1; fi
[ "$CHECK" = 1 ] && { echo; echo "afx-bootstrap --check: ready. Run without --check to install into $DEST"; exit 0; }

echo "2. fetch scripts/afx-guard from $HUB_SLUG@$REF"
SRC="$DEST/src/hub"
mkdir -p "$DEST/src" "$DEST/bin" || exit 1
if [ ! -d "$SRC/.git" ]; then
  gh repo clone "$HUB_SLUG" "$SRC" -- --depth 1 --filter=blob:none --no-checkout --quiet >/dev/null 2>&1 \
    || { echo "  FAIL  could not fetch $HUB_SLUG" >&2; exit 2; }
fi
git -C "$SRC" sparse-checkout init --cone >/dev/null 2>&1
git -C "$SRC" sparse-checkout set scripts/afx-guard >/dev/null 2>&1
git -C "$SRC" fetch --depth 1 origin "$REF" --quiet >/dev/null 2>&1 || { echo "  FAIL  ref $REF not found" >&2; exit 2; }
git -C "$SRC" checkout --quiet FETCH_HEAD >/dev/null 2>&1 || { echo "  FAIL  checkout failed" >&2; exit 2; }
SHA=$(git -C "$SRC" rev-parse HEAD)
[ -d "$SRC/scripts/afx-guard" ] || { echo "  FAIL  scripts/afx-guard missing in $REF" >&2; exit 2; }
ok "fetched $SHA"

echo "3. export to $DEST/afx-guard"
if [ -d "$DEST/afx-guard" ] && [ -f "$DEST/afx-guard/.exported-from-sha" ] && [ "$(cat "$DEST/afx-guard/.exported-from-sha")" = "$SHA" ]; then
  ok "already at $SHA"
else
  [ -d "$DEST/afx-guard" ] && { rm -rf "$DEST/afx-guard.prev"; mv "$DEST/afx-guard" "$DEST/afx-guard.prev"; did "previous export kept at afx-guard.prev"; }
  cp -R "$SRC/scripts/afx-guard" "$DEST/afx-guard" && echo "$SHA" > "$DEST/afx-guard/.exported-from-sha" && did "exported $(ls "$DEST/afx-guard" | wc -l | tr -d ' ') entries"
fi

for _pf in afx-config.afx.json afx-config-defaults.afx.sh; do   # the private tenant preset travels with the export when the hub has it
  if [ -f "$DEST/afx-guard/$_pf" ]; then ok "preset $_pf exported"; fi
done

echo "4. launcher"
L="$DEST/afx-guard/afx-terminal-agent-launcher.sh"
if [ -f "$L" ]; then
  printf '#!/bin/bash\nexport AFX_GUARD_DIR="%s"\nexec bash "%s" "$@"\n' "$DEST/afx-guard" "$L" > "$DEST/bin/afx-terminal-agent-launcher"
  chmod +x "$DEST/bin/afx-terminal-agent-launcher" 2>/dev/null
  ok "installed $DEST/bin/afx-terminal-agent-launcher"
  if [ -f "$DEST/afx-guard/afx" ]; then
    printf '#!/bin/bash\nexport AFX_GUARD_DIR="%s"\nexec bash "%s" "$@"\n' "$DEST/afx-guard" "$DEST/afx-guard/afx" > "$DEST/bin/afx"
    chmod +x "$DEST/bin/afx" 2>/dev/null
    ok "installed $DEST/bin/afx (short name: afx list, afx <key>, afx fleet, afx gate ...)"
    case "$(uname -s)" in   # Windows: cmd and PowerShell cannot run the bash wrapper, so add afx.cmd beside it (bin/ is on the user PATH)
      MINGW*|MSYS*|CYGWIN*)
        printf '@echo off\r\nset "AFX_BASH=%%ProgramFiles%%\\Git\\bin\\bash.exe"\r\nif not exist "%%AFX_BASH%%" set "AFX_BASH=bash.exe"\r\n"%%AFX_BASH%%" "%%~dp0..\\afx-guard\\afx" %%*\r\n' > "$DEST/bin/afx.cmd"
        ok "installed $DEST/bin/afx.cmd (cmd and PowerShell; make sure $DEST/bin is on the Windows user PATH)" ;;
    esac
  fi
  echo "        add to PATH:  export PATH=\"$DEST/bin:\$PATH\"   (and export AFX_GUARD_DIR=\"$DEST/afx-guard\")"
else
  echo "  note  this ref predates the renamed launcher; use $DEST/afx-guard/afx-terminal-agent-launcher.sh"
fi

echo "5. registry"
if [ "$REGISTRY" = 1 ]; then
  if [ -n "${AFX_PROJECTS_JSON:-}" ] && [ -f "$AFX_PROJECTS_JSON" ]; then ok "using \$AFX_PROJECTS_JSON"
  elif [ -f "$DEST/afx-projects.json" ] || [ -f "$HOME/afx-projects.json" ] || [ -f "$HOME/Projects/afx-projects.json" ] || [ -f "$DEST/allforx-projects.json" ] || [ -f "$HOME/allforx-projects.json" ] || [ -f "$HOME/Projects/allforx-projects.json" ]; then ok "registry already present"
  elif [ -f "$DEST/afx-guard/afx-projects.example.json" ]; then
    cp "$DEST/afx-guard/afx-projects.example.json" "$DEST/afx-projects.json" && did "stub at $DEST/afx-projects.json: edit it to this machine's real paths, then export AFX_PROJECTS_JSON=$DEST/afx-projects.json"
  fi
fi
echo
echo "afx-bootstrap: done at $SHA. Next (manual, per machine): gh auth is already set; install the Claude Code hooks with"
echo "  AFX_GUARD_DIR=$DEST/afx-guard bash $DEST/afx-guard/afx-install-claude-hooks.sh"
echo "and connect the AFX MCP through your Claude account's connectors (account-bound, not a shared secret)."
