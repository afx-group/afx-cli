#!/bin/sh
# AFX CLI smoke test: install a release into a throwaway home and run the documented first-run commands as a new user would.
#   sh scripts/smoke.sh [--tarball PATH_OR_URL] [--version X.Y.Z] [--strict] [--dir REPO]
#
# Report-only by default: every line is PASS, FAIL or INFO and the script exits 0 unless the install itself fails. With --strict it
# exits 1 when any FAIL line was printed (use that as the release gate).
# What it proves:
#   1. the installer works from nothing (checksum verified by install.sh) into a temp AFX_HOME and HOME;
#   2. the commands the README quick start tells a new user to run work on that clean install (no hidden machine setup needed);
#   3. PARITY: every `afx <command>` the README shows in a code block is listed in `afx help` of the installed release.
# It never touches your real ~/.afx: HOME and AFX_HOME both point into a temp folder, removed on exit.
# --dir REPO: run the project commands in this existing git repo (dry runs only, nothing is written there). Without it, if the current
# folder is not inside a git repo, a throwaway repo is created in the temp folder.
set -u
TARBALL=""; VERSION=""; STRICT=0; REPO_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tarball) TARBALL="${2:-}"; shift ;;
    --version) VERSION="${2:-}"; shift ;;
    --strict) STRICT=1 ;;
    --dir) REPO_DIR="${2:-}"; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "usage: sh scripts/smoke.sh [--tarball PATH_OR_URL] [--version X.Y.Z] [--strict] [--dir REPO]" >&2; exit 2 ;;
  esac
  shift
done
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/afx-cli-smoke.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT INT TERM
FAILS=0; PASSES=0
pass() { PASSES=$((PASSES+1)); echo "PASS  $1"; }
fail() { FAILS=$((FAILS+1)); echo "FAIL  $1"; }
info() { echo "INFO  $1"; }
export HOME="$T/home"; export AFX_HOME="$T/home/.afx"; mkdir -p "$HOME"
unset AFX_PROJECTS_JSON AFX_LICENSE

# 1. install from nothing
[ -n "$TARBALL" ] && export AFX_CLI_URL="$TARBALL"
[ -n "$VERSION" ] && export AFX_CLI_VERSION="$VERSION"
if sh "$ROOT/install.sh" > "$T/install.log" 2>&1; then pass "install.sh installed a release into a temp home"; else fail "install.sh failed: $(tail -n 2 "$T/install.log" | tr '\n' ' ')"; echo "smoke: $PASSES passed, $FAILS failed (install failed, nothing else can run)"; exit 1; fi
A="$AFX_HOME/bin/afx"; [ -x "$A" ] || { fail "no executable $A after install"; exit 1; }

# 2. a repo to run project commands in
if [ -n "$REPO_DIR" ]; then P="$REPO_DIR"; WRITE_OK=0
elif git rev-parse --git-dir >/dev/null 2>&1; then P="$(pwd)"; WRITE_OK=0
else P="$T/proj"; mkdir -p "$P"; (cd "$P" && git init -q . && printf '{"name":"smoke","scripts":{"test":"echo ok"}}\n' > package.json && git add package.json && git -c user.email=smoke@example.invalid -c user.name=smoke commit -qm init); WRITE_OK=1; fi
info "project folder: $P (writes allowed: $WRITE_OK)"

# run NAME 'EXPECTED EXITS (space separated)' ARGS...: output goes to $T/out; "Missing afx-projects.json" means the command needs machine setup a new user does not have
run() {
  name="$1"; want="$2"; shift 2
  ( cd "$P" && "$A" "$@" ) > "$T/out" 2>&1; rc=$?
  ok=0; for w in $want; do [ "$rc" = "$w" ] && ok=1; done
  if grep -q "Missing afx-projects.json" "$T/out"; then fail "$name: needs a machine registry (afx-projects.json) that a clean install does not have (exit $rc)"
  elif [ "$ok" = 1 ]; then pass "$name (exit $rc)"
  else fail "$name: exit $rc, wanted $want: $(head -n 1 "$T/out" | cut -c1-120)"; fi
}
run "afx help" "0" help
run "afx doctor" "0 1" doctor
run "afx init --project (dry run)" "0" init --project
run "afx where (exit 2 = folder not an approved AFX place, by design)" "0 1 2" where
run "afx license status" "0" license status
run "afx license check afx_cli:pro (no licence: not entitled)" "1" license check afx_cli:pro
run "afx rules check" "0 1" rules check
run "afx brief" "0" brief
if [ "$WRITE_OK" = 1 ]; then
  run "afx init --project --write" "0" init --project --write
  [ -f "$P/afx.config.json" ] && pass "afx.config.json was written" || fail "afx init --project --write wrote no afx.config.json"
  run "afx doctor after init" "0" doctor
fi

# 3. parity: README commands vs `afx help`
"$A" help > "$T/help.txt" 2>&1
awk '/^```/ {f=!f; next} f && /^afx([ \t]|$)/ {print}' "$ROOT/README.md" | sed 's/[ \t]*#.*$//' | while IFS= read -r line; do
  set -- $line; shift; w1="${1:-}"; w2="${2:-}"
  [ -n "$w1" ] || continue
  case "$w1" in -*) continue ;; esac
  if grep -q "afx $w1" "$T/help.txt"; then echo "PARITY-OK $line"; else echo "PARITY-MISSING $line"; fi
done > "$T/parity.txt"
miss=$(grep -c '^PARITY-MISSING' "$T/parity.txt"); okc=$(grep -c '^PARITY-OK' "$T/parity.txt")
if [ "$miss" = 0 ]; then pass "README parity: all $okc documented commands are in afx help"; else fail "README parity: $miss documented command(s) not in afx help"; grep '^PARITY-MISSING' "$T/parity.txt" | sed 's/^/        /'; fi

echo "smoke: $PASSES passed, $FAILS failed"
[ "$STRICT" = 1 ] && [ "$FAILS" -gt 0 ] && exit 1
exit 0
