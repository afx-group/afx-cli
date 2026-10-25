#!/bin/bash
# afx-secret-scan.sh: HIGH-PRECISION push-gate detector. Separate from afx-mask-secrets.sh on purpose: the masker is a DISPLAY
# filter (over-masking is fine there); a gate that refuses a push needs few false positives. Reports `file:line rule` ONLY, never the
# matched value.   afx-secret-scan.sh [--name LABEL] [FILE...]      (no FILE or "-" = stdin, labelled LABEL, default "stdin")
# Flags: vendor key formats (sk_/rk_ live|test, whsec_, re_, gh[pousr]_, AKIA, sk-ant-, JWT with 3 segments, PEM private key),
#        URL credentials (scheme://user:pass@ with a non-placeholder password), and assignments whose LEFT side is an env-style
#        name (ALL_CAPS_WITH_UNDERSCORES) or a key/secret/token/password/credential name and whose RIGHT side is a quoted or bare
#        literal of >= 24 chars, no spaces, containing letters AND digits.
# Does NOT flag: JSX props (tokens={...}, key={...}), identifiers/calls without a literal (const resetKey = useX()), comments that
#        only name a variable, single-case slugs with separators (storage key names like auth_token_storage_key_v2).
# Exit: 0 clean, 1 findings (one `file:line rule` per finding on stdout), 2 usage.
set -u
export LC_ALL=C
NAME=stdin; FILES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) [ $# -ge 2 ] || { echo "usage: afx-secret-scan.sh [--name LABEL] [FILE...]" >&2; exit 2; }; NAME="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]:-$0}" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    -) FILES="$FILES|-"; shift ;;
    -*) echo "usage: afx-secret-scan.sh [--name LABEL] [FILE...]" >&2; exit 2 ;;
    *) FILES="$FILES|$1"; shift ;;
  esac
done
[ -n "$FILES" ] || FILES="|-"
rc=0
OLDIFS="$IFS"; IFS='|'
for f in $FILES; do
  IFS="$OLDIFS"
  [ -n "$f" ] || continue
  if [ "$f" = "-" ]; then label="$NAME"; src="/dev/stdin"; else
    [ -r "$f" ] || { echo "afx-secret-scan: cannot read $f" >&2; exit 2; }
    label="$f"; [ "$NAME" = stdin ] || label="$NAME"; src="$f"
  fi
  awk -v F="$label" '
  function report(rule) { printf "%s:%d %s\n", F, NR, rule; found++ }
  function bad_pw(pw) { return pw ~ /^(password|passwd|pass|secret|changeme|example|xxx+|\*+|<.*>|your[-_]?password|user|test|dummy)$/ || pw ~ /^\*\*\*/ }
  BEGIN { found = 0 }
  {
    line = $0
    if (line ~ /-----BEGIN [A-Z ]*PRIVATE KEY-----/) { report("pem-private-key") }
    if (line ~ /(^|[^A-Za-z0-9_])(sk|rk)_(live|test)_[0-9A-Za-z]{8,}/) report("stripe-key")
    if (line ~ /(^|[^A-Za-z0-9_])whsec_[0-9A-Za-z]{8,}/) report("stripe-webhook-secret")
    if (line ~ /(^|[^A-Za-z0-9_])re_[0-9A-Za-z]{6,}_[0-9A-Za-z]{12,}/) report("resend-key")
    if (line ~ /(^|[^A-Za-z0-9_])gh[pousr]_[0-9A-Za-z]{20,}/) report("github-token")
    if (line ~ /(^|[^A-Za-z0-9_])AKIA[0-9A-Z]{16}/) report("aws-access-key")
    if (line ~ /sk-ant-[0-9A-Za-z_-]{10,}/) report("anthropic-key")
    if (line ~ /(^|[^A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+/) report("jwt")
    rest = line
    while (match(rest, /:\/\/[^\/@ :"\047]+:[^\/@ "\047]+@/)) {
      seg = substr(rest, RSTART + 3, RLENGTH - 4); pw = seg; sub(/^[^:]*:/, "", pw)
      if (!bad_pw(pw) && pw !~ /^\$/) { report("url-credentials"); break }
      rest = substr(rest, RSTART + RLENGTH)
    }
    rest = line; prev = ""
    while (match(rest, /["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?[ \t]*[=:][ \t]*["\047`]?[A-Za-z0-9_+\/=-]+/)) {
      m = substr(rest, RSTART, RLENGTH); after = substr(rest, RSTART + RLENGTH, 1)
      before = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
      rest = substr(rest, RSTART + RLENGTH)
      name = m; sub(/^["\047]/, "", name); sub(/["\047]?[ \t]*[=:].*$/, "", name)
      op = m; sub(/^[^=:]*/, "", op); op = substr(op, 1, 1)
      lit = m; sub(/^[^=:]*[=:][ \t]*/, "", lit)
      q = ""; if (lit ~ /^["\047`]/) { q = substr(lit, 1, 1); lit = substr(lit, 2) }
      if (before ~ /[A-Za-z0-9_$.]/) continue
      if (after == "=" || after == ">") continue
      if (length(lit) < 24) continue
      if (q != "") { if (after != q) continue } else { if (after != "" && after !~ /[ \t,;)}\]"\047`]/) continue }
      if (lit ~ /^=/) continue
      if (lit !~ /[A-Za-z]/ || lit !~ /[0-9]/) continue
      if (lit ~ /\// && lit ~ /^[a-z.\/_-]+$/) continue
      # single-case slug with separators (storage key / identifier names), not a secret
      if (lit ~ /[_-]/ && (lit !~ /[A-Z]/ || lit !~ /[a-z]/)) continue
      envstyle = (name ~ /^[A-Z][A-Z0-9]*(_[A-Z0-9]+)+$/)
      keyname = (tolower(name) ~ /(key|secret|token|password|passwd|credential)/)
      if (name == "key" && op == "=") continue
      if (envstyle || keyname) { report("secret-assignment"); break }
    }
  }
  END { exit (found > 0) ? 1 : 0 }
  ' "$src"
  [ $? -eq 0 ] || rc=1
  IFS='|'
done
IFS="$OLDIFS"
exit $rc
