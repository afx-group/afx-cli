#!/bin/bash
# afx-fake-data-lint.sh: ADVISORY review aid that flags CANDIDATES for
# "fabricated / hardcoded data rendered as a live metric" in .ts/.tsx/.js/.jsx.
#
#   scripts/afx-guard/afx-fake-data-lint.sh [--strict] [root ...]   (default: ".")
#   scripts/afx-guard/afx-fake-data-lint.sh --selftest
#
# Why: the 2026-10-01 readiness audit found this trust-risk repeating across the
# portfolio (several dashboards, messaging screens and brochure pages
# brochure) and noted there was no CI lint for hardcoded stats. Owner rule: demo data
# must be clearly labelled; an invented number is never presented as a real, live one.
#
# Exit codes: 0 = advisory run (candidates are printed but do NOT fail), even if some
# were found. With --strict: 1 if any candidate was found. 2 = bad usage/root.
# Output: `CANDIDATE <file>:<line>: <snippet>` per hit, then a trailing summary count.
#
# Heuristics (all conservative; FALSE POSITIVES ARE EXPECTED — a hit means "go look",
# never "this is definitely fake"):
#   literal-metric  identifier whose camel/snake TOKENS include a metric word (count,
#                   total, users, active, score, rate, pct, percent, revenue, stats,
#                   metric, dau, mau, views, members, sessions, downloads, signups,
#                   visitors, customers, subscribers, live) assigned (= or :), incl. a
#                   JSX attr `={..}`, a bare numeric literal of 2+ digits
#                   (e.g. `activeUsers = 1234`, `activeSessions: 188`, `skillsLive: 222`).
#                   Token matching (not substrings) avoids generate/state/status/account.
#                   Tokens like max/min/limit/timeout/size/port/index/page exclude the
#                   hit (config, not metrics); 4-digit years and `12px`-style are ignored.
#   literal-fallback  `x ?? 1234` / `x || 1234` on a line with a metric word: a made-up
#                   number that shows when the live source is empty or failing.
#   jsx-value       `value=`/`amount=`/`stat=`/`number=`/`figure=` given a numeric literal
#                   when the same/adjacent line carries a label/title/caption naming a
#                   metric word.
#   jsx-text        `>1,234<`, `>{1234}<` or `>1,234 active users<` JSX text with a metric
#                   word on the same or adjacent line.
#   fake-rows       2+ consecutive object-literal rows with an id/name/email/title key AND
#                   a numeric metric key (a hardcoded table/leaderboard).
#   [beside live data source, no demo/not-verified marker]  suffix: the same file also
#                   reads genuinely-live data (useQuery/useGet*/fetch(/count(/db.select/
#                   findMany/prisma.) — the audit's named anti-pattern of a hardcoded value
#                   rendered beside a real DB count with nothing telling the viewer.
# Config-constant tuning (2026-10-01): identifiers carrying a SOFT config token (particle,
#   scroll, depth, bar, tax, utterance/speech/audio, speed, fps, scale, batch, step, tick,
#   frame, radius, px, sample[Rate], ...) are treated as UI/animation/fiscal-table config and NOT flagged
#   (particleCount, BAR_COUNT, scrollDepthPct, taxPct, utterance.rate), UNLESS the same
#   identifier also carries a live-metric token (users, votes, views, members, sessions,
#   revenue, engagement, completion, success, civic, ...), e.g. `scrollViews: 900` still
#   flags. `completionRate`, `civicScore`, `totalVotes`, `relatedUsers` have no config
#   token and keep flagging. Dotted properties fold the object name in (utterance.rate).
#   HARD tokens (max/min/limit/delay/duration/size/...) always exclude, as before.
# Not flagged: lines sourced from variables/props/useQuery (no numeric literal), 0/1-digit
#   numbers, comment lines, and any line carrying `afx-fake-data-ok` (or preceded by one).
# Skipped by path (EXPECTED to hold constants; counted + noted, never flagged): node_modules,
#   dist, build, .next, coverage, .git, .claude, generated, public (static bundles), *.d.ts, *.min.js, __tests__,
#   __mocks__, e2e, scripts, *.test.*, *.spec.*, *.stories.*, and any path containing
#   demo|mock|fixture|seed|sample|backup (matched on the path RELATIVE to the scan root).
# Labeled files: a file whose text contains a demo marker (demo, simulated, illustrative,
#   not verified, sample/fake/mock/placeholder/dummy data) is treated as labeled — noted
#   in the summary, not flagged. A marker anywhere hides a file, so keep markers honest.
#
# Portability: classic macOS awk + gawk (no \b, no {n,m}, tolower() not IGNORECASE),
# bash 3.2 (no associative arrays, no ${v,,}), grep/find/tr only.
set -u

# ---- per-file scanner (awk). Emits "C<TAB>line<TAB>snippet" and "LABELED" ----------
AWK_PROG='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function isMetricIdent(id,    t, n, i, low, hasLower, tok, hit, cfg, liv) {
  hasLower = (id ~ /[a-z]/)
  low = id
  if (hasLower) { gsub(/[A-Z]/, "_&", low) }
  low = tolower(low)
  if (low ~ /^_?(dau|mau|wau)$/) return 1
  n = split(low, tok, "_")
  hit = 0; cfg = 0; liv = 0
  for (i = 1; i <= n; i++) {
    if (tok[i] in EX) return 0
    if (tok[i] in KW) hit = 1
    if (tok[i] in CFG) cfg = 1
    if (tok[i] in LIVE) liv = 1
  }
  # soft config tokens (particleCount, taxPct, scrollDepthPct, BAR_COUNT) exclude the
  # hit UNLESS a live-metric token (votes/users/views/...) is also present.
  if (cfg && !liv) return 0
  return hit
}
function digits(s,   d) { d = s; gsub(/[^0-9]/, "", d); return length(d) }
function window(i,   w) { w = tolower(L[i-1] " " L[i] " " L[i+1]); return w }
function addhit(i, kind) { if (!(i in HIT)) { HIT[i] = kind } }
BEGIN {
  split("count counts total totals users active score scores rate pct percent percentage revenue stats metric metrics dau mau views members sessions downloads signups visitors customers subscribers live", k, " ")
  for (j in k) KW[k[j]] = 1
  split("max min limit timeout delay interval duration width height size offset retry retries ttl index port page threshold default per take skip top font z opacity padding margin radius step length decimals digits fixed precision ms seconds minutes hours days", e, " ")
  for (j in e) EX[e[j]] = 1
  split("particle particles scroll depth bar bars tax taxes utterance speech audio synth pitch volume spread velocity gravity easing spring damping stiffness speed fps dpi scale batch chunk bins buckets steps tick ticks frame frames anim animation transition layer layers px radius sample sampling", c, " ")
  for (j in c) CFG[c[j]] = 1
  split("users user votes vote views members sessions downloads signups visitors customers subscribers revenue engagement completion success participants dau mau wau civic", lv, " ")
  for (j in lv) LIVE[lv[j]] = 1
  METRIC_WORD = "(^|[^a-z])(count|total|users|active|score|rate|pct|percent|revenue|stats|metric|dau|mau|views|members|sessions|downloads|signups|visitors|customers|subscribers)"
}
{ L[NR] = $0; N = NR }
END {
  all = ""
  for (i = 1; i <= N; i++) all = all " " L[i]
  lowall = tolower(all)
  if (lowall ~ /demo|simulated|illustrative|not verified|sample data|fake data|mock data|placeholder data|dummy/) { print "LABELED"; exit }
  live = (all ~ /useQuery|useGet[A-Z]|useSWR|fetch\(|\.count\(|count\(\*\)|db\.(select|query)|findMany|prisma\./)
  L[0] = ""; L[N+1] = ""
  for (i = 1; i <= N; i++) {
    raw = L[i]
    if (raw ~ /^[ \t]*(\/\/|\*|\/\*)/) continue
    if (raw ~ /afx-fake-data-ok/ || L[i-1] ~ /afx-fake-data-ok/) continue
    # literal-metric / jsx-value
    rest = raw
    while (match(rest, /[A-Za-z_][A-Za-z0-9_]*[ \t]*[:=][ \t]*[{"\x27`]?[ \t]*-?[0-9]/)) {
      seg = substr(rest, RSTART, RLENGTH)
      tail = substr(rest, RSTART + RLENGTH - 1)
      before = substr(rest, 1, RSTART - 1)
      rest = substr(rest, RSTART + RLENGTH)
      id = seg; sub(/[ \t]*[:=].*/, "", id)
      # `utterance.rate = 0.8`: fold the object name into the identifier so its tokens count
      if (match(before, /[A-Za-z0-9_]+\.$/)) id = substr(before, RSTART, RLENGTH - 1) "_" id
      if (!match(tail, /^[0-9][0-9,._]*/)) continue
      num = substr(tail, 1, RLENGTH); nxt = substr(tail, RLENGTH + 1, 1)
      if (nxt ~ /[A-Za-z]/ || digits(num) < 2) continue
      if (num ~ /^(19|20)[0-9][0-9]$/) continue
      if (isMetricIdent(id)) { addhit(i, "literal-metric"); break }
      if (id ~ /^(value|amount|stat|number|figure)$/) {
        w = window(i)
        if (w ~ /(label|title|caption)[ \t]*[=:]/ && w ~ METRIC_WORD) { addhit(i, "jsx-value"); break }
      }
    }
    lc = tolower(raw)
    # literal-fallback
    if (!(i in HIT) && raw ~ /(\?\?|\|\|)[ \t]*-?[0-9][0-9,._]*[0-9]/ && lc ~ METRIC_WORD && lc !~ /(max|min|limit|timeout|delay|interval|port)/)
      addhit(i, "literal-fallback")
    # jsx-text
    if (!(i in HIT) && (raw ~ /[^=-]>[ \t]*\$?[0-9][0-9,.]*[0-9][KkMm+%]?[ \t]*(<|[A-Za-z])/ || raw ~ />[ \t]*\{[ \t]*[0-9][0-9,.]*[0-9][ \t]*\}/)) {
      if (window(i) ~ METRIC_WORD) addhit(i, "jsx-text")
    }
    # fake-rows: consecutive object rows with an identity key and a numeric metric key
    if (lc ~ /^[ \t]*\{.*(id|name|email|user|title)[a-z0-9_]*[ \t]*:.*(count|total|users|active|score|rate|pct|percent|revenue|views|members|amount|value)[a-z0-9_]*[ \t]*:[ \t]*[0-9]/) {
      if (rows == 0) rowstart = i
      rows++
      if (rows == 2) HIT[rowstart] = "fake-rows"
    } else if (lc !~ /^[ \t]*$/) rows = 0
  }
  for (i = 1; i <= N; i++) if (i in HIT) {
    s = trim(L[i]); if (length(s) > 120) s = substr(s, 1, 117) "..."
    tag = ""
    if (live) tag = "  [beside live data source, no demo/not-verified marker]"
    print "C\t" i "\t[" HIT[i] "] " s tag
  }
}
'

scan_file() { awk "$AWK_PROG" "$1" 2>/dev/null; }

skip_path() {  # $1 = path relative to root; return 0 if expected-to-have-constants
  local p
  p="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  case "$p" in
    */node_modules/*|*/dist/*|*/build/*|*/.next/*|*/coverage/*|*/.git/*|*/.claude/*|*/generated/*|*/public/*|*.bundle.js) return 0;;
    */__tests__/*|*/__mocks__/*|*/e2e/*|*/scripts/*) return 0;;
    *.d.ts|*.min.js|*.test.*|*.spec.*|*.stories.*) return 0;;
    *demo*|*mock*|*fixture*|*seed*|*sample*|*backup*) return 0;;
  esac
  return 1
}

run_scan() {  # $1 = strict(0/1); rest = roots. Prints candidates + summary; returns per --strict.
  local strict="$1"; shift
  local roots=("$@") root f out cands=0 files=0 skipped=0 labeled=0 scanned=0 line snippet
  [ ${#roots[@]} -eq 0 ] && roots=(".")
  for root in "${roots[@]}"; do
    [ -d "$root" ] || { echo "afx-fake-data-lint: root not found: $root" >&2; return 2; }
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if skip_path "$f"; then skipped=$((skipped + 1)); continue; fi
      scanned=$((scanned + 1))
      out="$(scan_file "$root/$f")"
      [ -n "$out" ] || continue
      if [ "$out" = "LABELED" ]; then labeled=$((labeled + 1)); continue; fi
      files=$((files + 1))
      while IFS="$(printf '\t')" read -r _ line snippet; do
        [ -n "$line" ] || continue
        echo "CANDIDATE $root/$f:$line: $snippet"
        cands=$((cands + 1))
      done <<EOT
$out
EOT
    done < <(cd "$root" && find . \( -name node_modules -o -name .git \) -prune -o -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \) -print 2>/dev/null | sed 's|^\./||' | sort)
  done
  echo "afx-fake-data-lint: $cands candidate(s) in $files file(s); scanned=$scanned, skipped-by-path=$skipped, labeled-demo-files-noted=$labeled. ADVISORY: review each; add an 'afx-fake-data-ok' comment or a visible demo label if intentional."
  if [ "$strict" = "1" ] && [ "$cands" -gt 0 ]; then return 1; fi
  return 0
}

selftest() {
  T=""
  local pass=0 fail=0 out rc
  T="$(mktemp -d "${TMPDIR:-/tmp}/afx-fake-data.XXXXXX")" || { echo "mktemp failed" >&2; return 2; }
  trap 'rm -rf "${T:-}"' EXIT
  mkdir -p "$T/src/pages" "$T/src/mocks" "$T/src/fixtures" "$T/src/components"
  cat > "$T/src/pages/Dashboard.tsx" <<'F'
export function Dashboard() {
  const activeUsers = 1234
  return <div>{activeUsers}</div>
}
F
  cat > "$T/src/pages/Live.tsx" <<'F'
import { useQuery } from '@tanstack/react-query'
export function Live() {
  const { data } = useQuery({ queryKey: ['stats'], queryFn: () => fetch('/api/stats').then(r => r.json()) })
  const activeUsers = data?.activeUsers
  const total = data.total
  const [count, setCount] = useState(0)
  const retryLimit = 30
  const state = "static"
  return <div>{activeUsers} {total} {count}</div>
}
F
  cat > "$T/src/mocks/stats.ts" <<'F'
export const activeUsers = 9999
F
  cat > "$T/src/fixtures/seed.ts" <<'F'
export const totalRevenue = 5000
F
  cat > "$T/src/components/Labeled.tsx" <<'F'
// DEMO data - not verified
export const skillsLive = 222
F
  cat > "$T/src/components/Mixed.tsx" <<'F'
const { data } = useGetStats()
const activeSessions: 188
const x = data?.total ?? 4321
F
  cat > "$T/src/components/Rows.tsx" <<'F'
const rows = [
  { id: 1, name: "a", views: 120 },
  { id: 2, name: "b", views: 340 },
]
F
  cat > "$T/src/components/Config.tsx" <<'F'
const confetti = { particleCount: 80, spread: 70 }
const BAR_COUNT = 21;
const p = { scrollDepthPct: 40, taxPct: 8.5 }
utterance.rate = 0.8;
const scrollViews = 900
F
  cat > "$T/src/components/Regress.tsx" <<'F'
const { data } = useGetStats()
const a = {
  totalVotes: 1847,
  civicScore: 742,
  relatedUsers: 247,
  completionRate: 0.9,
}
export const S = () => (
  <div>
    <span>Active users</span>
    <p>12</p>
    <b>Uptime users</b>
    <i>99.9%</i>
  </div>
)
F
  cat > "$T/src/components/Ok.tsx" <<'F'
const memberCount = 4500 // afx-fake-data-ok
F

  out="$(run_scan 0 "$T")"; rc=$?
  chk() { # name cond
    if [ "$2" = "1" ]; then echo "PASS: $1"; pass=$((pass + 1)); else echo "FAIL: $1"; fail=$((fail + 1)); fi
  }
  has() { printf '%s\n' "$out" | grep -q "$1" && echo 1 || echo 0; }
  chk "advisory exit 0 despite candidates (rc=$rc)" "$([ "$rc" = 0 ] && echo 1 || echo 0)"
  chk "fabricated const activeUsers = 1234 flagged" "$(has 'Dashboard.tsx:2:')"
  chk "useQuery-sourced metrics NOT flagged" "$(printf '%s\n' "$out" | grep -q 'Live.tsx' && echo 0 || echo 1)"
  chk "mock/fixture/seed-path files skipped" "$(printf '%s\n' "$out" | grep -qE 'mocks/|fixtures/' && echo 0 || echo 1)"
  chk "demo-labeled file not flagged" "$(printf '%s\n' "$out" | grep -q 'Labeled.tsx' && echo 0 || echo 1)"
  chk "activeSessions: 188 beside live source flagged with live tag" "$(printf '%s\n' "$out" | grep 'Mixed.tsx:2:' | grep -q 'beside live data source' && echo 1 || echo 0)"
  chk "?? fallback literal flagged" "$(has 'Mixed.tsx:3:.*literal-fallback')"
  chk "fake rows flagged" "$(has 'Rows.tsx:2:.*fake-rows')"
  chk "afx-fake-data-ok suppresses" "$(printf '%s\n' "$out" | grep -q 'Ok.tsx' && echo 0 || echo 1)"
  chk "particleCount NOT flagged" "$(has 'Config.tsx:1:' | tr 01 10)"
  chk "BAR_COUNT NOT flagged" "$(has 'Config.tsx:2:' | tr 01 10)"
  chk "scrollDepthPct/taxPct NOT flagged" "$(has 'Config.tsx:3:' | tr 01 10)"
  chk "utterance.rate NOT flagged" "$(has 'Config.tsx:4:' | tr 01 10)"
  chk "scrollViews (config token + live token) STILL flagged" "$(has 'Config.tsx:5:')"
  chk "REGRESSION totalVotes flagged" "$(has 'Regress.tsx:3:.*totalVotes')"
  chk "REGRESSION civicScore flagged" "$(has 'Regress.tsx:4:.*civicScore')"
  chk "REGRESSION relatedUsers flagged" "$(has 'Regress.tsx:5:.*relatedUsers')"
  chk "REGRESSION completionRate beside live source flagged w/ live tag" "$(printf '%s\n' "$out" | grep 'Regress.tsx:6:' | grep -q 'beside live data source' && echo 1 || echo 0)"
  chk "REGRESSION JSX stat <p>12</p> flagged" "$(has 'Regress.tsx:11:.*jsx-text')"
  chk "REGRESSION JSX stat 99.9% flagged" "$(has 'Regress.tsx:13:.*jsx-text')"
  chk "summary count printed (12 candidates)" "$(has ': 12 candidate(s)')"
  run_scan 1 "$T" >/dev/null; rc=$?
  chk "--strict exits 1 with candidates (rc=$rc)" "$([ "$rc" = 1 ] && echo 1 || echo 0)"
  rm -f "$T/src/pages/Dashboard.tsx" "$T/src/components/Mixed.tsx" "$T/src/components/Rows.tsx" "$T/src/components/Regress.tsx" "$T/src/components/Config.tsx"
  run_scan 1 "$T" >/dev/null; rc=$?
  chk "--strict exits 0 when clean (rc=$rc)" "$([ "$rc" = 0 ] && echo 1 || echo 0)"
  echo "selftest: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}

STRICT=0; ARGS=()
for a in "$@"; do
  case "$a" in
    --selftest) selftest; exit $? ;;
    --strict) STRICT=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) ARGS+=("$a") ;;
  esac
done
run_scan "$STRICT" ${ARGS[@]+"${ARGS[@]}"}
exit $?
