#!/bin/bash
# afx-branch-census.sh: classify EVERY remote branch of every registered repo against its default branch,
# and check the registry against reality. Read-only: the only write is `git fetch --prune` (remote-tracking refs).
# It never merges, deletes, or pushes. Deleting a remote branch always needs the owner's OK.
#
#   scripts/afx-guard/afx-branch-census.sh [--registry FILE] [--only KEY] [--no-fetch] [--stale-days N] [--deep]
#                                          [--out report.md] [--tsv branches.tsv] [--json BRANCH_DEBT_BACKLOG.json] [--registry-check [--gh]] [--scan-root DIR]
#   scripts/afx-guard/afx-branch-census.sh --repo PATH [--default main] ...      (no registry; used by the tests)
#
# Classes (the whole point: tell "already in main" from "real unmerged work" from "conflicting work"):
#   CONTAINED        every commit is already in the default branch (branch is an ancestor)   -> safe to delete after OK
#   ALREADY-APPLIED  not an ancestor, but merging it changes nothing (squash/cherry-picked)   -> safe to delete after OK
#   CLEAN-AHEAD      has changes main lacks and merges cleanly                                -> open a PR, gate, merge
#   CONFLICT         has changes main lacks and CONFLICTS with main                           -> needs the author / a human
#   NO-BASE          no common history with the default branch (unrelated); a merge cannot be tested -> triage by hand
#   STALE-UNMERGED   unmerged and older than --stale-days; merge not tested (use --deep)      -> triage
#   PRESERVED        archive/ backup/ rescue/ preserve/ salvage/ recovered- prefixes: permanent unless the OWNER names the prefix; never suggested for deletion
#
# --registry-check also reports, per registry entry: missing path, wrong origin, local branch not the default,
# ahead/behind origin, dirty files, worktree count, and (with --gh) the GitHub default branch; plus DUPLICATE-CLONE
# for any other clone of a registered remote under --scan-root. Use `--strict` to exit 1 when anything is flagged.
# Needs git >= 2.38 (merge-tree --write-tree). Portable to macOS bash 3.2, Linux and Git Bash.
set -u
_AFX_BC_DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
. "$_AFX_BC_DIR/afx-platform.sh"

REGISTRY="${AFX_REGISTRY:-}"; ONLY=""; FETCH=1; STALE_DAYS=60; DEEP=0; OUT=""; TSV=""; JSON=""; RCHECK=0; GH=0; STRICT=0; SCAN_ROOT=""
REPOS_ARG=(); DEFAULT_ARG="main"
while [ $# -gt 0 ]; do
  case "$1" in
    --registry) REGISTRY="$2"; shift 2;;
    --only) ONLY="$2"; shift 2;;
    --repo) REPOS_ARG+=("$2"); shift 2;;
    --default) DEFAULT_ARG="$2"; shift 2;;
    --no-fetch) FETCH=0; shift;;
    --stale-days) STALE_DAYS="$2"; shift 2;;
    --deep) DEEP=1; shift;;
    --out) OUT="$2"; shift 2;;
    --tsv) TSV="$2"; shift 2;;
    --json) JSON="$2"; shift 2;;
    --registry-check) RCHECK=1; shift;;
    --gh) GH=1; shift;;
    --strict) STRICT=1; shift;;
    --scan-root) SCAN_ROOT="$2"; shift 2;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "afx-branch-census: unknown argument $1" >&2; exit 64;;
  esac
done

PY=""; for c in python3 python; do if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import json' >/dev/null 2>&1; then PY="$c"; break; fi; done
[ -z "$PY" ] && [ -z "${REPOS_ARG[0]:-}" ] && { echo "afx-branch-census: python is needed to read the registry" >&2; exit 2; }
to_unix() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1" 2>/dev/null || echo "$1"; else echo "$1"; fi; }

# Registry default locations (first that exists).
if [ -z "$REGISTRY" ] && [ -z "${REPOS_ARG[0]:-}" ]; then
  for c in "$HOME/Projects/afx-projects.json" "$HOME/Projects/allforx-projects.json" "/c/Users/$USER/Projects/afx-projects.json" "/c/Users/$USER/Projects/allforx-projects.json" "$(dirname "${AFX_CLONES_ROOT:-/nonexistent}")/afx-projects.json" "$(dirname "${AFX_CLONES_ROOT:-/nonexistent}")/allforx-projects.json"; do
    [ -f "$c" ] && { REGISTRY="$c"; break; }
  done
  [ -z "$REGISTRY" ] && { echo "afx-branch-census: no registry found; pass --registry FILE or --repo PATH" >&2; exit 2; }
fi

# Entries as tab-separated: key  path  defaultBranch  repo  paused
ENTRIES="$(mktemp)"; trap 'rm -f "$ENTRIES" "$ENTRIES.m" "$ENTRIES.t" "$ENTRIES.rc"' EXIT
if [ -n "${REPOS_ARG[0]:-}" ]; then
  for r in "${REPOS_ARG[@]}"; do printf '%s\t%s\t%s\t%s\t%s\n' "$(basename "$r")" "$r" "$DEFAULT_ARG" "-" "false" >> "$ENTRIES"; done
else
  "$PY" - "$REGISTRY" <<'PYEOF' > "$ENTRIES"
import json, sys
sys.stdout.reconfigure(newline=chr(10))  # Windows Python would otherwise emit CRLF and bash would read a stray CR
d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
for p in d.get("projects", []):
    print("\t".join([p.get("key", ""), p.get("path") or "-", p.get("defaultBranch") or "main", p.get("repo") or "-", "true" if p.get("paused") else "false"]))
PYEOF
fi

now=$(date +%s)
[ -n "$TSV" ] && : > "$TSV"
RAW="$(mktemp)"; : > "$RAW"
ISSUES=0
issue() { ISSUES=$((ISSUES+1)); echo "  ISSUE: $*"; }
norm_remote() { # https://github.com/Owner/Repo.git or git@github.com:Owner/Repo.git -> owner/repo (lowercase)
  echo "$1" | sed -e 's#^git@github.com:#github.com/#' -e 's#^https\{0,1\}://##' -e 's#^[^/]*@##' -e 's#^github.com/##' -e 's#\.git$##' | tr 'A-Z' 'a-z'
}
PRESERVE_RE='^(archive|backup|rescue|preserve|salvage)/|^recovered-|/archive/|^wip/.*snapshot'

report() { if [ -n "$OUT" ]; then printf '%s\n' "$*" >> "$OUT"; else printf '%s\n' "$*"; fi; }
[ -n "$OUT" ] && : > "$OUT"
report "# Branch census, $(date '+%Y-%m-%d %H:%M %Z')"
report ""
report "Read-only. Classes: CONTAINED / ALREADY-APPLIED are safe to delete **after the owner's OK**; CLEAN-AHEAD needs a PR; CONFLICT needs its author; STALE-UNMERGED needs triage; PRESERVED is kept on purpose."
report ""
report "| repo | default | branches | CONTAINED | ALREADY-APPLIED | CLEAN-AHEAD | CONFLICT | NO-BASE | STALE-UNMERGED | PRESERVED |"
report "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|"

DETAILS="$(mktemp)"; : > "$DETAILS"
while IFS="$(printf '\t')" read -r key path def repo paused; do
  [ -z "$key" ] && continue
  [ "$repo" = "-" ] && repo=""
  [ "$path" = "-" ] && path=""
  [ -n "$ONLY" ] && [ "$ONLY" != "$key" ] && continue
  [ "$paused" = "true" ] && { report "| $key | $def | (paused in registry, skipped) | | | | | | | |"; continue; }
  p="$(to_unix "$path")"
  if [ -z "$p" ] || ! git -C "$p" rev-parse --git-dir >/dev/null 2>&1; then report "| $key | $def | **no git repo at registry path** | | | | | | | |"; ISSUES=$((ISSUES+1)); continue; fi
  [ "$FETCH" = 1 ] && afx_platform_timeout 240 git -C "$p" fetch -q --prune origin 2>/dev/null
  base="origin/$def"
  if ! git -C "$p" rev-parse --verify -q "$base" >/dev/null; then report "| $key | $def | **$base not found (fetch failed or wrong default)** | | | | | | | |"; ISSUES=$((ISSUES+1)); continue; fi
  basetree=$(git -C "$p" rev-parse "$base^{tree}")
  git -C "$p" for-each-ref --merged="$base" --format='%(refname:short)' refs/remotes/origin > "$ENTRIES.m" 2>/dev/null
  c_cont=0; c_app=0; c_clean=0; c_conf=0; c_stale=0; c_pres=0; c_nobase=0; total=0
  git -C "$p" for-each-ref --format='%(refname:short)%09%(committerdate:unix)%09%(committerdate:iso-strict)%09%(authorname)%09%(contents:subject)' refs/remotes/origin > "$ENTRIES.t"
  while IFS="$(printf '\t')" read -r ref ts iso auth subj; do
    [ -z "$ref" ] && continue
    [ "$ref" = "origin" ] && continue          # the symbolic origin/HEAD short name
    [ "$ref" = "$base" ] && continue
    name="${ref#origin/}"; [ "$name" = "HEAD" ] && continue
    total=$((total+1))
    age=$(( (now - ${ts:-$now}) / 86400 ))
    if echo "$name" | grep -Eq "$PRESERVE_RE"; then cls=PRESERVED; c_pres=$((c_pres+1))
    elif grep -Fxq "$ref" "$ENTRIES.m"; then cls=CONTAINED; c_cont=$((c_cont+1))
    elif ! git -C "$p" merge-base "$base" "$ref" >/dev/null 2>&1; then cls=NO-BASE; c_nobase=$((c_nobase+1))
    elif [ "$age" -gt "$STALE_DAYS" ] && [ "$DEEP" = 0 ]; then cls=STALE-UNMERGED; c_stale=$((c_stale+1))
    else
      mt=$(git -C "$p" merge-tree --write-tree "$base" "$ref" 2>/dev/null); rc=$?
      first=$(echo "$mt" | head -1)
      if [ $rc -eq 0 ] && [ "$first" = "$basetree" ]; then cls=ALREADY-APPLIED; c_app=$((c_app+1))
      elif [ $rc -eq 0 ]; then cls=CLEAN-AHEAD; c_clean=$((c_clean+1))
      elif [ $rc -eq 1 ]; then cls=CONFLICT; c_conf=$((c_conf+1))
      else cls=STALE-UNMERGED; c_stale=$((c_stale+1)); fi
    fi
    ahead=$(git -C "$p" rev-list --count "$base..$ref" 2>/dev/null)
    [ -n "$TSV" ] && printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$cls" "$name" "${ahead:-?}" "$age" >> "$TSV"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$repo" "$def" "$(git -C "$p" rev-parse "$base")" "$cls" "$name" "${ahead:-0}" "$age" "$iso" "$(printf '%s' "$auth|$subj" | tr '\t' ' ')" >> "$RAW"
    case "$cls" in CLEAN-AHEAD|CONFLICT) printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$cls" "$name" "${ahead:-?}" "$age" >> "$DETAILS";; esac
  done < "$ENTRIES.t"
  report "| $key | $def | $total | $c_cont | $c_app | $c_clean | $c_conf | $c_nobase | $c_stale | $c_pres |"
done < "$ENTRIES"

if [ -s "$DETAILS" ]; then
  report ""; report "## Work that is not in the default branch yet (not stale)"; report ""
  report "| repo | class | branch | commits ahead | days since last commit |"; report "|---|---|---|---:|---:|"
  sort -t"$(printf '\t')" -k1,1 -k2,2 -k5,5n "$DETAILS" | head -200 | while IFS="$(printf '\t')" read -r k c b a g; do report "| $k | $c | \`$b\` | $a | $g |"; done
fi
rm -f "$DETAILS"

if [ "$RCHECK" = 1 ]; then
  report ""; report "## Registry check"; report ""
  REPORT_BUF="$(mktemp)"
  while IFS="$(printf '\t')" read -r key path def repo paused; do
    [ -z "$key" ] && continue
    [ "$repo" = "-" ] && repo=""
    [ "$path" = "-" ] && path=""
    [ -n "$ONLY" ] && [ "$ONLY" != "$key" ] && continue
    [ "$paused" = "true" ] && continue
    p="$(to_unix "$path")"
    if ! git -C "$p" rev-parse --git-dir >/dev/null 2>&1; then echo "- $key: ISSUE path is not a git repo: $path" >> "$REPORT_BUF"; ISSUES=$((ISSUES+1)); continue; fi
    msgs=""
    url=$(git -C "$p" remote get-url origin 2>/dev/null); have=$(norm_remote "$url"); want=$(echo "$repo" | tr 'A-Z' 'a-z')
    [ -n "$want" ] && [ "$have" != "$want" ] && msgs="$msgs origin is $have, registry says $want;"
    cur=$(git -C "$p" branch --show-current 2>/dev/null)
    [ "$cur" != "$def" ] && msgs="$msgs checked-out branch is '${cur:-detached}', registry default is $def;"
    if git -C "$p" rev-parse --verify -q "origin/$def" >/dev/null; then
      lr=$(git -C "$p" rev-list --left-right --count "origin/$def...HEAD" 2>/dev/null)
      behind=${lr%%[[:space:]]*}; ahead=${lr##*[[:space:]]}
      [ "${ahead:-0}" != 0 ] && msgs="$msgs $ahead local commit(s) not on origin/$def;"
      [ "${behind:-0}" != 0 ] && msgs="$msgs $behind behind origin/$def;"
    fi
    dirty=$(git -C "$p" status --porcelain -uno 2>/dev/null | wc -l | tr -d ' ')
    untr=$(git -C "$p" status --porcelain 2>/dev/null | grep -c '^??')
    [ "$dirty" != 0 ] && msgs="$msgs $dirty modified tracked file(s);"
    [ "$untr" != 0 ] && msgs="$msgs $untr untracked file(s);"
    if [ "$GH" = 1 ] && command -v gh >/dev/null 2>&1 && [ -n "$repo" ]; then
      gd=$(gh api "repos/$repo" --jq .default_branch 2>/dev/null)
      [ -n "$gd" ] && [ "$gd" != "$def" ] && msgs="$msgs GitHub default branch is '$gd', registry says $def;"
    fi
    if [ -n "$msgs" ]; then echo "- $key: ISSUE$msgs" >> "$REPORT_BUF"; ISSUES=$((ISSUES+1)); else echo "- $key: ok" >> "$REPORT_BUF"; fi
  done < "$ENTRIES"
  # Duplicate clones: another checkout of a registered remote that is not the registry path.
  if [ -n "$SCAN_ROOT" ] && [ -d "$SCAN_ROOT" ]; then
    find "$SCAN_ROOT" -maxdepth 8 \( -name node_modules -o -name .claude -o -name Pods -o -name build -o -name .pnpm \) -prune -o -type d -name .git -print 2>/dev/null | sed 's#/\.git$##' | while IFS= read -r d; do
      u=$(git -C "$d" remote get-url origin 2>/dev/null); [ -z "$u" ] && continue
      n=$(norm_remote "$u")
      while IFS="$(printf '\t')" read -r k pth df rp pz; do
        [ "$rp" = "-" ] && rp=""
        [ -z "$rp" ] && continue
        [ "$(echo "$rp" | tr 'A-Z' 'a-z')" != "$n" ] && continue
        rp_unix="$(to_unix "$pth")"
        [ "$(cd "$d" 2>/dev/null && pwd)" = "$(cd "$rp_unix" 2>/dev/null && pwd)" ] && continue
        echo "- $k: DUPLICATE-CLONE $d (registry path is $pth)" >> "$REPORT_BUF"
      done < "$ENTRIES"
    done
  fi
  REPORT_BUF_COPY="$ENTRIES.rc"; cp "$REPORT_BUF" "$REPORT_BUF_COPY"
  while IFS= read -r line; do report "$line"; done < "$REPORT_BUF"
  grep -c 'DUPLICATE-CLONE' "$REPORT_BUF" >/dev/null 2>&1 && ISSUES=$((ISSUES + $(grep -c 'DUPLICATE-CLONE' "$REPORT_BUF")))
  rm -f "$REPORT_BUF"
fi

if [ -n "$JSON" ] && [ -n "$PY" ]; then
  "$PY" - "$RAW" "$JSON" "${REPORT_BUF_COPY:-}" "$(afx_platform_os)" "$(git --version | sed 's/git version //')" <<'PYJSON'
import json, sys, datetime, collections
raw, out, regf, machine, gv = sys.argv[1:6]
repos = collections.OrderedDict()
for line in open(raw, encoding="utf-8", errors="replace"):
    f = line.rstrip("\n").split("\t")
    if len(f) < 10: continue
    key, repo, default, dsha, cls, name, ahead, age, iso, rest = f[:10]
    author, _, subject = rest.partition("|")
    r = repos.setdefault(key, {"key": key, "repo": repo, "default": default, "default_sha": dsha, "branches": [], "counts": {}})
    r["branches"].append({"name": name, "class": cls, "ahead": int(ahead or 0), "age_days": int(age or 0), "last_commit": iso, "author": author, "subject": subject[:120]})
    r["counts"][cls] = r["counts"].get(cls, 0) + 1
order = ["CONTAINED", "ALREADY-APPLIED", "CLEAN-AHEAD", "CONFLICT", "NO-BASE", "STALE-UNMERGED", "PRESERVED"]
for r in repos.values():
    r["branches"].sort(key=lambda b: (order.index(b["class"]) if b["class"] in order else 99, b["age_days"]))
rc = []
if regf:
    try:
        for l in open(regf, encoding="utf-8", errors="replace"):
            if l.startswith("- ") and ": ISSUE" in l:
                k, _, msg = l[2:].partition(": ISSUE")
                rc.append({"key": k, "issues": [m.strip() for m in msg.split(";") if m.strip()]})
    except OSError:
        pass
json.dump({"generated": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "machine": machine, "git_version": gv, "repos": list(repos.values()), "registry_check": rc}, open(out, "w"), indent=1)
PYJSON
fi
rm -f "$RAW"
report ""
report "Flagged items: $ISSUES. This report never changes a branch. Safe-to-delete classes still need the owner's OK."
[ "$STRICT" = 1 ] && [ "$ISSUES" -gt 0 ] && exit 1
exit 0
