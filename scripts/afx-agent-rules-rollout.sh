#!/bin/bash
# afx-agent-rules-rollout.sh: after the hub's agent-rules template changes, bring every live registered repo's rules block current,
# as ONE docs-only pull request per repo, sequentially (one landing at a time; no parallel installs or builds).
#   afx-agent-rules-rollout.sh [--apply] [--only key[,key...]] [--projects FILE] [--registry FILE] [--title TEXT]
# Without --apply it only reports, per repo, whether its block differs from the template (read-only). With --apply, for each live,
# unpaused repo that has a clone on this machine: a worktree off origin/main under <clone>/.claude/worktrees/, afx-agent-rules-sync.sh
# --write there, an explicit-path commit, afx-land.sh --gate-docs-only, then --cleanup. A repo whose block is already current is
# skipped; a repo that fails is reported and the loop continues. Exit 1 if any repo failed. Makes no model calls.
#   AFX_COMMIT_TRAILER   optional text appended to each commit message (for example attribution lines)
# --projects: the shared registry (default: scripts/afx-guard/registry/projects.json, for status and paused).
# --registry: this machine's composed file, for each clone's folder (default: $AFX_REGISTRY, else ~/afx-projects.json when it
#   exists, else ~/Projects/afx-projects.json; the older allforx-projects.json name is also read). A repo is joined to its folder by key OR alias, in either direction: the shared
#   key "app" finds the local entry keyed "my-app" (or one that lists "app" as an alias), so the two files need not
#   spell a key the same way. An exact key match always wins over an alias match.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
APPLY=0; ONLY=""; PROJECTS="$HERE/registry/projects.json"; REGISTRY="${AFX_REGISTRY:-}"
if [ -z "$REGISTRY" ]; then
  REGISTRY="$HOME/Projects/afx-projects.json"
  for _c in "$HOME/afx-projects.json" "$HOME/allforx-projects.json" "$HOME/Projects/afx-projects.json" "$HOME/Projects/allforx-projects.json"; do [ -f "$_c" ] && { REGISTRY="$_c"; break; }; done
fi
TITLE="docs(agent-rules): refresh the AFX rules block from the hub template"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift;;
    --only) ONLY="$2"; shift 2;;
    --projects) PROJECTS="$2"; shift 2;;
    --registry) REGISTRY="$2"; shift 2;;
    --title) TITLE="$2"; shift 2;;
    -h|--help) sed -n '2,13p' "$0"; exit 0;;
    *) echo "afx-agent-rules-rollout: unknown argument: $1" >&2; exit 2;;
  esac
done
[ -f "$PROJECTS" ] || { echo "afx-agent-rules-rollout: no projects file: $PROJECTS" >&2; exit 2; }
[ -f "$REGISTRY" ] || { echo "afx-agent-rules-rollout: no registry: $REGISTRY" >&2; exit 2; }
SYNC="$HERE/afx-agent-rules-sync.sh"; LAND="$HERE/afx-land.sh"
DAY=$(date -u +%Y-%m-%d)

# key|repo|path for every live, unpaused project that has a folder on this machine
PY=python; command -v python >/dev/null 2>&1 || PY=python3
LIST=$($PY - "$PROJECTS" "$REGISTRY" "$ONLY" <<'PY'
import json, os, sys
shared = json.load(open(sys.argv[1], encoding="utf-8-sig"))["projects"]
local = json.load(open(sys.argv[2], encoding="utf-8-sig"))["projects"]
local = list(local.values()) if isinstance(local, dict) else local
def names(p):
    return {str(n).lower() for n in [p.get("key", "")] + list(p.get("aliases") or []) if n}
by_key = {p["key"]: p.get("path", "") for p in local}
def find_path(sp):
    if by_key.get(sp["key"]):
        return by_key[sp["key"]]
    want = names(sp)
    for lp in local:
        if lp.get("path") and want & names(lp):
            return lp["path"]
    return ""
only = {k for k in sys.argv[3].split(",") if k}
for p in shared:
    if p.get("status") != "live" or p.get("paused"):
        continue
    if only and p["key"] not in only:
        continue
    path = find_path(p)
    if path and os.path.isdir(path):
        print(f'{p["key"]}|{p["repo"]}|{path}')
PY
) || { echo "afx-agent-rules-rollout: could not read the registries" >&2; exit 2; }
# python on Windows ends its lines with CRLF; a stray CR would become part of the path ("...repo?") and break every git call
LIST=$(printf '%s\n' "$LIST" | tr -d '\r')
[ -n "$LIST" ] || { echo "afx-agent-rules-rollout: no live repos with a clone here${ONLY:+ matching $ONLY}"; exit 0; }

ok=0; skipped=0; failed=0
while IFS='|' read -r key repo path; do
  [ -n "$key" ] || continue
  if [ "$APPLY" = 0 ]; then
    if bash "$SYNC" --check "$path" >/dev/null 2>&1; then echo "current   $key ($repo)"; else echo "DIFFERS   $key ($repo)"; fi
    continue
  fi
  echo "=== $key ($repo)"
  ferr=$(git -C "$path" fetch origin main -q 2>&1) || { echo "FAILED    $key: fetch failed: $(printf '%s' "$ferr" | tr '\n' ' ' | cut -c1-140)"; failed=$((failed+1)); continue; }
  wt="$path/.claude/worktrees/rules-rollout-$DAY"; br="wip/rules-rollout-$DAY"
  if [ -e "$wt" ]; then echo "FAILED    $key: $wt already exists (finish or remove it first)"; failed=$((failed+1)); continue; fi
  git -C "$path" worktree add -b "$br" "$wt" origin/main >/dev/null 2>&1 || { echo "FAILED    $key: could not create the worktree"; failed=$((failed+1)); continue; }
  bash "$SYNC" --write "$wt" >/dev/null 2>&1
  changed=$(git -C "$wt" status --porcelain | sed 's/^...//')
  while IFS= read -r f; do [ -n "$f" ] && git -C "$wt" add -- "$f"; done <<< "$changed"
  # Judge by what git would actually commit: a rewritten file with only line-ending noise stages as nothing.
  if [ -z "$changed" ] || git -C "$wt" diff --cached --quiet; then
    echo "current   $key: already matches the template"
    git -C "$path" worktree remove --force "$wt" >/dev/null 2>&1; git -C "$path" branch -D "$br" >/dev/null 2>&1
    skipped=$((skipped+1)); continue
  fi
  changed=$(git -C "$wt" diff --cached --name-only)
  msg="$TITLE"$'\n\n'"Generated by afx-agent-rules-sync.sh from the hub template (scripts/afx-guard/agent-rules/afx-agent-rules.template.md)."$'\n'"Files: $(printf '%s' "$changed" | tr '\n' ' ')"
  [ -n "${AFX_COMMIT_TRAILER:-}" ] && msg="$msg"$'\n\n'"$AFX_COMMIT_TRAILER"
  git -C "$wt" commit -q -m "$msg" || { echo "FAILED    $key: commit failed"; failed=$((failed+1)); continue; }
  out=$(cd "$wt" && bash "$LAND" --gate-docs-only --slug "$repo" --title "$TITLE" 2>&1)
  rc=$?
  line=$(printf '%s\n' "$out" | grep -E 'LANDED|STOP \(' | tail -1)
  if [ "$rc" = 0 ] && printf '%s' "$line" | grep -q LANDED; then
    echo "landed    $key: $(printf '%s' "$line" | sed 's/^afx-land: //' | cut -c1-120)"
    (cd "$wt" && bash "$LAND" --cleanup --no-janitor >/dev/null 2>&1) || true
    [ -e "$wt" ] && echo "note      $key: worktree folder left at $wt (use windows/afx-worktree-remove.ps1)"
    ok=$((ok+1))
  else
    echo "FAILED    $key: ${line:-afx-land exit $rc}"; printf '%s\n' "$out" | tail -4 | sed 's/^/    | /'
    failed=$((failed+1))
  fi
done <<< "$LIST"
[ "$APPLY" = 1 ] && echo "rollout: landed $ok, already current $skipped, failed $failed"
[ "$failed" = 0 ]
