#!/bin/bash
# afx-machine-conf.sh: show or set this machine's identity for the AFX guard (~/.claude/hooks/afx-guard/machine.conf).
# The policy guard briefing, afx-where-am-i.sh, the statusline and afx-orchestrate.sh read it. Without it the briefing
# says machine=unknown and falls back to per-OS defaults. Keys written here (every other key, e.g. heavy_local=,
# max_load=, is kept as it is):
#   machine=<display name>  registry=<key of registry/paths.<key>.json>  root=<clones root>  hub=<this machine's afx-hub clone>
#   scripts/afx-guard/afx-machine-conf.sh                                   print the current file and the registry's machines
#   scripts/afx-guard/afx-machine-conf.sh --machine lenovo-windows          print what it would write (root/hub from the registry)
#   scripts/afx-guard/afx-machine-conf.sh --machine lenovo-windows --write  write it. Owner decision 2026-10-21: an
#                                                                           agent may run --write for its OWN machine
#                                                                           (the key named in a registry/paths.<key>.json
#                                                                           the agent did not just add itself) as part of
#                                                                           a normal setup/bootstrap task; it must not
#                                                                           write a DIFFERENT machine's identity.
#   --name "<display name>"  keeps the current machine= unless given (default for a new file: the registry key)
# Mac, Linux and Windows Git Bash. Needs python3 or python for the JSON.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CONF="${AFX_MACHINE_CONF:-$HOME/.claude/hooks/afx-guard/machine.conf}"
REG="${AFX_REGISTRY_DIR:-$HERE/registry}"
KEY=""; NAME=""; WRITE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --machine) KEY="${2:?--machine needs a registry key}"; shift 2 ;;
    --name) NAME="${2:?--name needs a value}"; shift 2 ;;
    --write) WRITE=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
get() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -1; }
machines() { ls "$REG"/paths.*.json 2>/dev/null | sed 's#.*/paths\.##; s#\.json$##' | tr '\n' ' '; }

if [ -z "$KEY" ]; then
  if [ -f "$CONF" ]; then echo "$CONF:"; sed 's/^/  /' "$CONF"; else echo "$CONF: missing (the briefing shows machine=unknown)"; fi
  echo "machines in the registry: $(machines)"
  exit 0
fi

P="$REG/paths.$KEY.json"
[ -f "$P" ] || { echo "no paths.$KEY.json in $REG (known: $(machines)). Add it to the registry with a normal hub PR first." >&2; exit 1; }
PY=$(command -v python3 || command -v python) || { echo "needs python3 or python" >&2; exit 1; }
# Windows Python cannot open /c/... paths; hand it the native form.
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi; }
# Forward slashes: node, Git Bash and the Mac all accept them, and they survive sed and `read` unchanged.
field() { "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); v=d.get("paths",{}).get("hub","") if sys.argv[2]=="hub" else d.get(sys.argv[2],""); print(v.replace("\\","/"))' "$(native "$P")" "$1"; }
ROOT=$(field root); HUBP=$(field hub)
[ -n "$ROOT" ] || { echo "paths.$KEY.json has no root" >&2; exit 1; }
[ -n "$NAME" ] || NAME=$(get machine)
[ -n "$NAME" ] || NAME="$KEY"

NEW="machine=$NAME
registry=$KEY
root=$ROOT"
[ -n "$HUBP" ] && NEW="$NEW
hub=$HUBP"
KEEP=$(grep -vE '^(machine|registry|root|hub)=' "$CONF" 2>/dev/null || true)
[ -n "$KEEP" ] && NEW="$NEW
$KEEP"

F="$REG/fleet.json"
if [ -f "$F" ]; then
  FL=$("$PY" -c 'import json,sys; m=[d for d in json.load(open(sys.argv[1], encoding="utf-8")).get("devices",[]) if d.get("key")==sys.argv[2]]; print("%s, %s GB: %s" % (m[0].get("name"), m[0].get("ramGb","?"), m[0].get("role","")) if m else "")' "$(native "$F")" "$KEY")
  [ -n "$FL" ] && echo "fleet: $FL" || echo "warning: $KEY is not in registry/fleet.json (add it there too)" >&2
fi
for d in "$ROOT" "$HUBP"; do [ -z "$d" ] || [ -d "$d" ] || echo "warning: $d does not exist on this machine" >&2; done
if [ "$WRITE" = 1 ]; then
  mkdir -p "$(dirname "$CONF")"
  printf '%s\n' "$NEW" > "$CONF.new" && mv "$CONF.new" "$CONF"
  echo "wrote $CONF:"; sed 's/^/  /' "$CONF"
else
  echo "would write $CONF:"; printf '%s\n' "$NEW" | sed 's/^/  /'
  echo "owner: re-run with --write (typed with the ! prefix) to apply"
fi
