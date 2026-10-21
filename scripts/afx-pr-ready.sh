#!/bin/bash
# afx-pr-ready.sh: which open PRs are SAFE to merge by rule, and (only with --execute) merge those.
#
#   scripts/afx-guard/afx-pr-ready.sh [--registry FILE] [--only KEY] [--repo owner/name] [--pr N] [--execute] [--max-merges N]
#   With --pr N only that PR is judged and the exit code is the verdict: 0 READY, 5 NOT-READY (afx-land.sh uses this).
#   --evidence-only judges ONLY the Evidence rules (section present, literal EXIT 0 / passing result, no failing EXIT, dependency
#   changes name a real gate); mergeability, labels and hard stops are ignored. Used by the optional GitHub check template.
#
# Default is a dry run: it prints READY / NOT-READY for every open PR and why. Nothing is merged without --execute.
# Policy (owner, 2026-10-08, Operating Standard section 2 item 4): "PRs should always be merged... If it's good, complete code then it merges to main."
# A PR is READY when ALL of these hold; everything else is a normal change and does NOT wait for the owner:
#   - base is the repo's default branch, not a draft, no hold/do-not-merge/needs-owner label
#   - GitHub says mergeable and the state is clean (or unstable: checks are disabled fleet-wide, see CLAUDE.md rule 9);
#     'behind' is NOT ready: main moved since the evidence was produced, so it must be re-gated
#   - the PR body has an Evidence section with a literal passing result (EXIT 0 / exit 0 / N passed): a failed or missing gate stops it
#     and no failing one: any non-zero EXIT in the Evidence stops it, except a baseline-table step that fails identically on main
#   - when package.json, a lockfile or another dependency manifest changes, that Evidence names a build, typecheck or test gate
#     (a docs-only check is not evidence for a dependency change)
# HARD STOPS that still need the owner (the label `owner-ok` waives them; it never waives a conflict, draft, stale base, missing Evidence or hold label):
#   - a secret-like value or an .env file in the diff (templates such as .env.example are fine)
#   - destructive SQL in a migration or .sql file (DROP TABLE/COLUMN/SCHEMA/DATABASE, TRUNCATE, DELETE FROM without WHERE)
#   - mass deletion: more than 200 removed tracked, non-generated files, unless the PR body says they were moved, renamed or generated
#   - deploy/runtime config that this policy does not mention (.replit, replit.nix, deploy/, .github/workflows/: Actions is retired fleet-wide)
# NOT stops any more: package.json, lockfiles, pnpm-workspace, CLAUDE.md, AGENTS.md and other rules files, the registry, machine-rules,
# non-destructive migrations, and change size. Dependabot majors are work items for an agent to port and test, not blind merges (see
# the Operating Standard); this tool only checks the evidence, so an agent must not call a major READY without a port and a passing gate.
# --execute re-fetches and re-checks each READY PR immediately before `gh pr merge --merge` (a normal merge, never a
# force or a push to main), merges at most --max-merges per run (default 3), and stops on the first failure.
# Anything it will not merge is left for the author. It never closes a PR or deletes a branch.
# Portable to bash 3.2. `gh` is overridable with AFX_GH (the tests use a stub).
set -u
_AFX_PR_DIR="${AFX_GUARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
. "$_AFX_PR_DIR/afx-platform.sh"
GH="${AFX_GH:-gh}"; REGISTRY="${AFX_REGISTRY:-}"; ONLY=""; EXEC=0; MAXM=3; REPOS=(); ONLYPR=""; EVONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --registry) REGISTRY="$2"; shift 2;;
    --only) ONLY="$2"; shift 2;;
    --repo) REPOS+=("$2"); shift 2;;
    --execute) EXEC=1; shift;;
    --max-merges) MAXM="$2"; shift 2;;
    --pr) ONLYPR="$2"; shift 2;;
    --evidence-only) EVONLY=1; shift;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "afx-pr-ready: unknown argument $1" >&2; exit 64;;
  esac
done
PY=""; for c in python3 python; do if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import json' >/dev/null 2>&1; then PY="$c"; break; fi; done
[ -z "$PY" ] && { echo "afx-pr-ready: python is needed" >&2; exit 2; }
if [ -z "${REPOS[0]:-}" ] && [ -z "$REGISTRY" ]; then
  for c in "$HOME/Projects/allforx-projects.json" "/c/Users/$USER/Projects/allforx-projects.json"; do [ -f "$c" ] && { REGISTRY="$c"; break; }; done
fi
LIST="$(mktemp)"; trap 'rm -f "$LIST" "$LIST.p" "$LIST.d" "$LIST.f"' EXIT
if [ -n "${REPOS[0]:-}" ]; then for r in "${REPOS[@]}"; do printf '%s\t%s\t%s\n' "$r" "main" "$r" >> "$LIST"; done
else
  [ -z "$REGISTRY" ] && { echo "afx-pr-ready: no registry; pass --registry or --repo" >&2; exit 2; }
  "$PY" - "$REGISTRY" "$ONLY" <<'PYEOF' > "$LIST"
import json, sys
sys.stdout.reconfigure(newline=chr(10))  # Windows Python would otherwise emit CRLF and bash would read a stray CR
d = json.load(open(sys.argv[1], encoding="utf-8-sig")); only = sys.argv[2]
for p in d.get("projects", []):
    if p.get("paused") or not p.get("repo") or (only and p.get("key") != only): continue
    print("\t".join([p["repo"], p.get("defaultBranch") or "main", p.get("key", "")]))
PYEOF
fi

# evaluate <detail.json> <files.json> <default-branch> -> prints "READY" or "NOT-READY<TAB>reasons"
evaluate() {
  AFX_EVIDENCE_ONLY="$EVONLY" "$PY" - "$1" "$2" "$3" <<'PYEOF'
import json, re, sys
def pages(path):                      # gh --paginate prints one JSON array per page, back to back
    s = open(path, encoding="utf-8-sig").read(); dec = json.JSONDecoder(); i = 0; out = []
    while i < len(s):
        while i < len(s) and s[i].isspace(): i += 1
        if i >= len(s): break
        v, i = dec.raw_decode(s, i); out.extend(v if isinstance(v, list) else [v])
    return out
d = json.load(open(sys.argv[1], encoding="utf-8-sig")); files = pages(sys.argv[2]); default = sys.argv[3]
why = []
if d["base"]["ref"] != default: why.append("base is %s, not %s" % (d["base"]["ref"], default))
if d.get("draft"): why.append("draft")
labels = [l["name"].lower() for l in d.get("labels", [])]
if any(l in ("hold", "do-not-merge", "needs-owner", "wip") for l in labels): why.append("label: " + ",".join(labels))
if re.search(r"\[(hold|wip|do not merge)\]", d.get("title", ""), re.I): why.append("title says hold/wip")
if d.get("mergeable") is not True: why.append("GitHub does not report it mergeable (conflict or still computing)")
st = d.get("mergeable_state", "")
if st == "behind": why.append("branch is behind main: re-gate after updating")
elif st not in ("clean", "unstable"): why.append("merge state is '%s'" % st)
body = d.get("body") or ""
if not (re.search(r"^#+\s*evidence", body, re.I | re.M) and re.search(r"EXIT:?\s*0\b|exit\s+0\b|\b\d+\s+(passed|pass)\b|0 failed", body, re.I)):
    why.append("no Evidence section with a literal passing result in the body")
# Dependency changes are a normal change, but "good, complete code" has to be shown by a real gate: when a manifest or
# lockfile changes, the Evidence must name a build, typecheck or test command. A docs-only check proves nothing about them.
DEPFILE = re.compile(r"(^|/)(package\.json|package-lock\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|yarn\.lock|requirements[^/]*\.txt|pyproject\.toml|Cargo\.(toml|lock)|Podfile(\.lock)?)$")
dep_files = sorted({f["filename"] for f in files if DEPFILE.search(f["filename"]) and f.get("status") != "removed"})
ev = re.split(r"^#+\s*evidence.*$", body, maxsplit=1, flags=re.I | re.M)
ev_text = ev[1] if len(ev) > 1 else ""
if dep_files and not re.search(r"\b(typecheck|tsc\b|build|vitest|jest|pytest|node --test|(pnpm|npm|yarn)( run)? test|cargo (test|build|check)|xcodebuild|expo export)", ev_text, re.I):
    why.append("dependency files changed (%s): the Evidence must show a build, typecheck or test gate, not a docs-only check" % ", ".join(dep_files[:3]))
# One passing line must not hide a failing one: every EXIT code written in the Evidence is read. A baseline table row
# "| step | EXIT a | EXIT b |" (main, merge result) is a regression when b is non-zero and differs from a; a step that
# already fails the same way on main (a == b) is not this PR's doing. On any other line the last EXIT is the result
# (so "before EXIT 1; after EXIT 0" passes) and a non-zero one is a failed gate.
failing = []
for line in ev_text.splitlines():
    # Only the literal token EXIT (as afx-gate-run / afx-land write it) counts. Lower-case prose such as a test name
    # "refuses with exit 8" is not a gate result.
    codes = [int(x) for x in re.findall(r"(?<![A-Za-z_])EXIT[:=]?\s*(\d+)\b", line)]
    if not codes: continue
    if line.lstrip().startswith("|") and len(codes) == 2:
        if codes[1] != 0 and codes[1] != codes[0]: failing.append("regression vs main (EXIT %d -> EXIT %d)" % (codes[0], codes[1]))
    elif codes[-1] != 0: failing.append("EXIT %d" % codes[-1])   # "before EXIT 1; after EXIT 0" on one line: the last code is the result
if failing: why.append("the Evidence shows a failing gate: " + ", ".join(failing[:3]))
owner_ok = "owner-ok" in labels
stops = []   # hard stops, waived only by the owner-ok label
GENERATED = re.compile(r"(^|/)(node_modules|dist|build|\.next|\.expo|\.turbo|coverage|__pycache__|\.cache|\.vite|out|Pods|DerivedData|\.gate-logs|\.verify-logs|\.agents/skills|\.claude/skills|\.github/skills|\.cursor/skills|\.local/skills|\.local/secondary_skills|\.local/mcp_skills)(/|$)|(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock|\.fingerprint)$|\.tsbuildinfo$")
removed = [f["filename"] for f in files if f.get("status") == "removed" and not GENERATED.search(f["filename"])]
if len(removed) > 200 and not re.search(r"\b(moved|renamed|relocat\w*|generated|regenerat\w*)\b", body, re.I):
    stops.append("mass deletion: %d tracked non-generated files removed and the body does not say moved/renamed/generated" % len(removed))
SECRET = re.compile(r"sk-[A-Za-z0-9_-]{20,}|sk_live_[0-9A-Za-z]{16,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|gh[pousr]_[0-9A-Za-z]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[abp]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{30,}|whsec_[0-9A-Za-z]{20,}")
URLPW = re.compile(r"(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis)://[^:\s/@]+:([^@\s]{6,})@")
PLACEHOLDER = re.compile(r"^(password|passwd|pass|secret|changeme|change-me|example|your[-_]?password|xxx+|\*+|<.*>|\$\{?\w+\}?|%s|\{\{.*\}\})$", re.I)
ENVFILE = re.compile(r"(^|/)\.env(\.(local|production|development|staging|test|prod|dev))?$", re.I)
secret_files = []
for f in files:
    name = f["filename"]
    if ENVFILE.search(name) and f.get("status") != "removed": secret_files.append(name + " (an .env file)")
    added = [l[1:] for l in (f.get("patch") or "").splitlines() if l.startswith("+") and not l.startswith("+++")]
    if any(SECRET.search(l) for l in added) or any((m.group(1) and not PLACEHOLDER.match(m.group(1))) for l in added for m in URLPW.finditer(l)):
        secret_files.append(name + " (secret-like text)")
if secret_files: stops.append("secret or .env value in the diff: " + ", ".join(sorted(set(secret_files))[:3]))
SQLFILE = re.compile(r"(\.sql$|(^|/)(migrations?|drizzle)/)", re.I)
DESTRUCTIVE = re.compile(r"\bDROP\s+(TABLE|COLUMN|SCHEMA|DATABASE)\b|\bTRUNCATE\b|\bDELETE\s+FROM\s+[\w\".]+\s*(;|$)", re.I | re.M)
# Read the SQL, not its prose: drop comments and string literals, and the event list of a trigger definition
# ("BEFORE UPDATE OR DELETE OR TRUNCATE ON t" guards a table; it destroys nothing). 2026-10-15: append-only audit and
# consent tables were stopped as "destructive" for the trigger that forbids TRUNCATE.
def sql_code(text):
    text = re.sub(r"--[^\n]*", "", text)
    text = re.sub(r"'(?:[^']|'')*'", "''", text)
    return re.sub(r"\b(BEFORE|AFTER|INSTEAD\s+OF)\s+[A-Z_,\s]+?\s+ON\b", r"\1 ON", text, flags=re.I)
sql_files = [f["filename"] for f in files if f.get("status") != "removed" and SQLFILE.search(f["filename"]) and
             DESTRUCTIVE.search(sql_code("\n".join(l[1:] for l in (f.get("patch") or "").splitlines() if l.startswith("+") and not l.startswith("+++"))))]
if sql_files: stops.append("destructive SQL (needs the owner's production approval): " + ", ".join(sorted(set(sql_files))[:3]))
deploy = sorted({f["filename"] for f in files if re.search(r"^\.replit$|^replit\.nix$|(^|/)deploy/|^\.github/workflows/", f["filename"])})
if deploy: stops.append("deploy/runtime config or a workflow (not covered by the hands-off policy; Actions is retired): " + ", ".join(deploy[:3]))
if stops and not owner_ok: why.append("hard stop, label owner-ok needed: " + "; ".join(stops))
import os
if os.environ.get("AFX_EVIDENCE_ONLY") == "1":
    why = [w for w in why if w.startswith(("no Evidence", "the Evidence shows", "dependency files changed"))]
print("READY" if not why else "NOT-READY\t" + "; ".join(why))
PYEOF
}

merged=0; ready_total=0; open_total=0
printf '%-8s %-22s %-6s %s\n' "VERDICT" "REPO" "PR" "TITLE / REASON"
while IFS="$(printf '\t')" read -r repo def key; do
  [ -z "$repo" ] && continue
  "$GH" api "repos/$repo/pulls?state=open&per_page=100" > "$LIST.p" 2>/dev/null || { printf '%-8s %-22s %-6s %s\n' "ERROR" "$repo" "-" "could not list PRs"; continue; }
  nums=$("$PY" -c 'import json,sys;print(" ".join(str(p["number"]) for p in json.load(open(sys.argv[1],encoding="utf-8-sig"))))' "$LIST.p")
  for n in $nums; do
    [ -n "$ONLYPR" ] && [ "$n" != "$ONLYPR" ] && continue
    open_total=$((open_total+1))
    "$GH" api "repos/$repo/pulls/$n" > "$LIST.d" 2>/dev/null; "$GH" api "repos/$repo/pulls/$n/files?per_page=100" --paginate > "$LIST.f" 2>/dev/null
    title=$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8-sig")).get("title","")[:60])' "$LIST.d")
    v=$(evaluate "$LIST.d" "$LIST.f" "$def")
    if [ "${v%%$(printf '\t')*}" = "READY" ]; then
      ready_total=$((ready_total+1)); printf '%-8s %-22s #%-5s %s\n' "READY" "$repo" "$n" "$title"
      if [ "$EXEC" = 1 ] && [ "$merged" -lt "$MAXM" ]; then
        # re-check immediately before merging: state can change between listing and now
        "$GH" api "repos/$repo/pulls/$n" > "$LIST.d" 2>/dev/null; "$GH" api "repos/$repo/pulls/$n/files?per_page=100" --paginate > "$LIST.f" 2>/dev/null
        v2=$(evaluate "$LIST.d" "$LIST.f" "$def")
        if [ "${v2%%$(printf '\t')*}" = "READY" ]; then
          if "$GH" pr merge "$n" -R "$repo" --merge >/dev/null 2>&1; then merged=$((merged+1)); echo "         merged $repo#$n"
          else echo "         MERGE FAILED $repo#$n: stopping" >&2; exit 1; fi
        else echo "         skipped $repo#$n: no longer ready (${v2#*$(printf '\t')})"; fi
      fi
    else
      printf '%-8s %-22s #%-5s %s\n           %s\n' "NOT" "$repo" "$n" "$title" "${v#*$(printf '\t')}"
    fi
  done
done < "$LIST"
echo
echo "open PRs: $open_total, ready by rule: $ready_total, merged this run: $merged$([ "$EXEC" = 1 ] || echo ' (dry run: pass --execute to merge)')"
if [ -n "$ONLYPR" ]; then [ "$ready_total" -ge 1 ] && exit 0; exit 5; fi
exit 0
