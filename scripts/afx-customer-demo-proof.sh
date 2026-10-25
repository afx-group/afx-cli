#!/bin/bash
# afx-customer-demo-proof.sh <dir>: proof that the generic edition works on a stranger's project (a small shop called afx-customer-demo).
# <dir> must be an existing, empty git repository (create it yourself: git init <dir>). Writes a tiny npm project, then runs the
# front door against it and prints every command with its literal exit code. Needs no licence, network or AFX machine state:
# it runs with an empty HOME and AFX_NO_PRESET=1, so the vendor's own presets can not leak in.
#   afx-customer-demo-proof.sh <dir>        exit 0 when every step gave its expected exit code, 1 when one did not, 2 on bad usage
set -u
DIR="${1:-}"; [ -d "$DIR/.git" ] || { echo "usage: afx-customer-demo-proof.sh <dir>   (an existing git repo; git init it first)" >&2; exit 2; }
G="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DIR="$(cd "$DIR" && pwd)"; FAKEHOME="$(mktemp -d)"; bad=0
cat > "$DIR/package.json" <<'J'
{ "name": "afx-customer-demo", "version": "1.0.0", "scripts": { "test": "node --test", "typecheck": "echo typecheck" }, "packageManager": "npm@10.0.0" }
J
mkdir -p "$DIR/src"; echo 'export const total = (items) => items.reduce((s, i) => s + i.price, 0);' > "$DIR/src/cart.js"
printf 'package-lock.json\nnode_modules/\n' > "$DIR/.gitignore"
step() { want="$1"; shift; echo "\$ $*"; out="$("$@" 2>&1)"; rc=$?; printf '%s\n' "$out" | cut -c1-200; echo "[exit $rc, expected $want]"; case "|$want|" in *"|$rc|"*) ;; *) bad=1 ;; esac; }
run() { env HOME="$FAKEHOME" AFX_NO_PRESET=1 AFX_GUARD_DIR="$G" bash "$G/afx" "$@"; }
cd "$DIR" || exit 2
step 0 run init --project --write
step 0 run project get packageManager
step 0 run project get git.defaultBranch
step 0 run doctor --dir "$DIR"
step 1 run rules check --dir "$DIR"
step 0 run license status
step 3 run rules render --dir "$DIR"
step 3 run rules sync --dir "$DIR"
step 3\|2 run design-preflight "$DIR"
echo "--- config written:"; cat "$DIR/afx.config.json" | head -30
echo "--- files in the project that mention AFX: $(grep -rli 'afx-hub\|allforx\|_clones' "$DIR" --exclude-dir=.git --exclude=afx.config.json 2>/dev/null | wc -l | tr -d ' ') (expected 0)"
rm -rf "$FAKEHOME"
[ "$bad" = 0 ] && echo "PROOF OK" || echo "PROOF FAILED"
exit "$bad"
