#!/bin/bash
# afx-api-hygiene-lint.sh: REPORT-ONLY static scan of a venture repo (at a git ref, no checkout) for the API
# security/error-handling classes that dominate the 2026-10-05 security findings (ops/readiness/_readiness/security/FINDINGS_*.md).
#
#   afx-api-hygiene-lint.sh <repo-path> [--ref REF] [--summary] [--max N] [--strict]
#
# Rules (id, severity): grep heuristics, so each hit is a LEAD to read, not a verdict. A clean run proves nothing about
# routes the patterns do not spell the same way.
#   MASS-ASSIGN     high  `...req.body` spread, or `.values(req.body)` / `.set(req.body)`: caller-controlled columns (role, price, userId, status)
#   BODY-IDENTITY   high  identity taken from the body: `userId = ... req.body.userId` (account-takeover class, seen in several product audits)
#   ERR-LEAK        med   5xx response echoing `.message`/`.stack` (internal detail, SQL text, paths)
#   EXPRESS4-ASYNC  med   express 4.x in package.json, async handlers present, no async-error wrapper: one rejected promise can crash the process
#   NO-PROC-HANDLER med   server repo (express dep) with no process.on('unhandledRejection'|'uncaughtException')
#   NO-SEC-HEADERS  med   server repo with neither helmet nor a setHeader for X-Content-Type-Options / CSP / HSTS
#   NO-RATE-LIMIT   med   server repo with no rate-limit library or limiter call anywhere
# Test files, node_modules, dist, archive, .claude are excluded. Output: `RULE path:line: text` then a per-rule count table.
# --summary prints only the table. --max N caps listed hits per rule (default 8). Exit 0 always (advisory); --strict exits 1 if
# any high-severity hit. 2 = usage. bash 3.2 safe; reads git objects only (no checkout, no fetch, no writes).
set -u
REPO=""; REF="HEAD"; SUMMARY=0; MAX=8; STRICT=0
while [ $# -gt 0 ]; do case "$1" in
  --ref) shift; REF="${1:-HEAD}" ;; --summary) SUMMARY=1 ;; --max) shift; MAX="${1:-8}" ;; --strict) STRICT=1 ;;
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
  -*) echo "afx-api-hygiene-lint: unknown option $1" >&2; exit 2 ;; *) REPO="$1" ;; esac; shift; done
[ -n "$REPO" ] || { echo "usage: afx-api-hygiene-lint.sh <repo-path> [--ref REF] [--summary] [--max N] [--strict]" >&2; exit 2; }
case "$MAX" in ''|*[!0-9]*) echo "afx-api-hygiene-lint: --max must be a number" >&2; exit 2 ;; esac
unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_PREFIX 2>/dev/null || true
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "afx-api-hygiene-lint: not a git repo: $REPO" >&2; exit 2; }
git -C "$REPO" rev-parse --verify -q "$REF^{commit}" >/dev/null || { echo "afx-api-hygiene-lint: unknown ref $REF" >&2; exit 2; }
SRC=( '*.ts' '*.js' '*.mjs' '*.cjs' ':(exclude)**/node_modules/**' ':(exclude)node_modules' ':(exclude).claude' ':(exclude)**/.claude/**'
      ':(exclude)**/archive/**' ':(exclude)**/dist/**' ':(exclude)**/*.test.*' ':(exclude)**/*.spec.*' ':(exclude)**/__tests__/**'
      ':(exclude)**/e2e/**' ':(exclude)**/test/**' ':(exclude)**/tests/**' ':(exclude)**/.migration-backup/**' ':(exclude)**/migration-backup/**' ':(exclude)**/triage/**' ':(exclude).migration-backup' ':(exclude)migration-backup' ':(exclude)triage' ':(exclude)docs' ':(exclude)archive' )
G() { git -C "$REPO" grep -I -n -E -e "$1" "$REF" -- "${SRC[@]}" 2>/dev/null | sed "s#^$REF:##"; }
TMP="$(mktemp "${TMPDIR:-/tmp}/afx-hyg.XXXXXX")"; trap 'rm -f "$TMP" "$TMP".*' EXIT
HIGH=0; : > "$TMP"
emit() { # emit <RULE> <sev> <file-with-hit-lines>
  local n; n="$(wc -l < "$3" | tr -d ' ')"
  printf '%s\t%s\t%s\n' "$1" "$2" "$n" >> "$TMP"
  [ "$2" = high ] && [ "$n" -gt 0 ] && HIGH=$((HIGH+n))
  if [ "$SUMMARY" = 0 ] && [ "$n" -gt 0 ]; then head -n "$MAX" "$3" | cut -c1-200 | sed "s#^#$1 #"; [ "$n" -gt "$MAX" ] && echo "$1 ... $((n-MAX)) more"; fi
}
G '\.\.\.req\.body|\.(values|set)\(req\.body\)' > "$TMP.a"; emit MASS-ASSIGN high "$TMP.a"
G '(userId|ownerId|authorId|accountId)[[:space:]]*=[^=].{0,60}req\.body\.(userId|ownerId|authorId|accountId)|req\.body\.userId[[:space:]]*\|\|' > "$TMP.b"; emit BODY-IDENTITY high "$TMP.b"
G 'status\(5[0-9][0-9]\)\.(json|send)\(.{0,80}(\.message|\.stack)' > "$TMP.c"; emit ERR-LEAK med "$TMP.c"
# repo-level rules apply only to a server repo (express dependency anywhere in a package.json at the ref)
PKGS="$(git -C "$REPO" grep -I -h -E '"express"[[:space:]]*:' "$REF" -- 'package.json' '**/package.json' ':(exclude)**/node_modules/**' ':(exclude)**/.claude/**' ':(exclude)**/archive/**' ':(exclude)**/triage/**' ':(exclude)**/migration-backup/**' ':(exclude)**/.migration-backup/**' ':(exclude).migration-backup' ':(exclude)migration-backup' ':(exclude)triage' ':(exclude)docs' ':(exclude)archive' 2>/dev/null)"
: > "$TMP.d"; : > "$TMP.e"; : > "$TMP.f"; : > "$TMP.g"
if [ -n "$PKGS" ]; then
  # express 4 is judged PER PACKAGE: async handlers and the async-error wrapper are counted only inside the package dir that depends on express 4
  git -C "$REPO" grep -I -l -E '"express"[[:space:]]*:[[:space:]]*"[~^>=<v ]*4(\.|")' "$REF" -- 'package.json' '**/package.json' ':(exclude)**/node_modules/**' ':(exclude)**/.claude/**' ':(exclude)**/archive/**' ':(exclude)**/triage/**' ':(exclude)**/migration-backup/**' ':(exclude)**/.migration-backup/**' ':(exclude).migration-backup' ':(exclude)migration-backup' ':(exclude)triage' ':(exclude)docs' ':(exclude)archive' 2>/dev/null | sed "s#^$REF:##" > "$TMP.p"
  while IFS= read -r pj; do
    [ -n "$pj" ] || continue; pd="$(dirname "$pj")"; ps=( "${SRC[@]}" ); [ "$pd" = "." ] || ps=( "$pd" "${SRC[@]}" )
    asyncn="$(git -C "$REPO" grep -I -n -E -e 'async[[:space:]]*\(?(req|_req|request)[,: )]' "$REF" -- "${ps[@]}" 2>/dev/null | wc -l | tr -d ' ')"
    wrap="$(git -C "$REPO" grep -I -n -E -e 'express-async-errors|asyncHandler|wrapAsync|catchAsync' "$REF" -- "${ps[@]}" 2>/dev/null | wc -l | tr -d ' ')"
    wrapdep="$(git -C "$REPO" show "$REF:$pj" 2>/dev/null | grep -c 'express-async-errors')"
    [ "$asyncn" -gt 0 ] && [ "$wrap" = 0 ] && [ "$wrapdep" = 0 ] && echo "$pj: express 4.x, $asyncn async handler line(s), no async-error wrapper" >> "$TMP.d"
  done < "$TMP.p"
  [ -n "$(G "process\.on\([\"'](unhandledRejection|uncaughtException)" | head -1)" ] || echo "(repo) no process.on('unhandledRejection'|'uncaughtException') handler found" > "$TMP.e"
  [ -n "$(G "helmet|setHeader\([\"'](X-Content-Type-Options|Content-Security-Policy|Strict-Transport-Security)|[\"'](X-Content-Type-Options|Content-Security-Policy|Strict-Transport-Security)[\"'][[:space:]]*:" | head -1)" ] || echo "(repo) no helmet and no security-header setHeader found" > "$TMP.f"
  [ -n "$(G 'express-rate-limit|rate-limiter-flexible|rateLimit\(|[Ll]imiter\(' | head -1)" ] || echo "(repo) no rate-limit library or limiter call found" > "$TMP.g"
else
  echo "(note) no express dependency at $REF: repo-level rules skipped" > "$TMP.n"
fi
emit EXPRESS4-ASYNC med "$TMP.d"; emit NO-PROC-HANDLER med "$TMP.e"; emit NO-SEC-HEADERS med "$TMP.f"; emit NO-RATE-LIMIT med "$TMP.g"
[ ! -s "$TMP.n" ] || cat "$TMP.n"
echo "== api-hygiene $(basename "$(cd "$REPO" && pwd)") @ $(git -C "$REPO" rev-parse --short "$REF")  (heuristic leads, not verdicts)"
awk -F'\t' '{printf "  %-16s %-5s %s\n",$1,$2,$3}' "$TMP"
[ "$STRICT" = 1 ] && [ "$HIGH" -gt 0 ] && exit 1
exit 0
