#!/bin/bash
# afx-bloat-check.sh: REPORT-ONLY repo bloat advisory. Never edits, fetches, fixes or fails a build.
#
#   afx-bloat-check.sh [repo-path] [--ref REF] [--max-mb N] [--top N] [--dirs N] [--summary]
#
# Reports for one repo (default $PWD): git object size (size-pack + loose), total tracked bytes at REF
# (default HEAD), the top N tracked files (default 10), the top N directories by tracked bytes (default 10, depth 2),
# and every tracked file over the advisory limit (default 5 MB, env AFX_BLOAT_MAX_MB) that is not allow-listed.
# --summary prints ONE line (used by afx-standard-check.sh): `OVER=<n> largest=<MB> <path> pack=<MiB> tracked=<MB>`.
#
# Allow list: `.afx-bloat-allow` at the repo root, one glob per line (shell case-glob, repo-relative path),
# `# why` comments allowed. Allow-listed files are listed as ALLOWED, not counted as OVER.
# Exit code: always 0 (advisory). 2 for usage errors. Portable: macOS bash 3.2 + BSD userland, Linux, Git Bash.
set -u
REPO=""; REF="HEAD"; MAXMB="${AFX_BLOAT_MAX_MB:-5}"; TOP=10; DIRS=10; SUMMARY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) shift; REF="${1:-HEAD}" ;; --max-mb) shift; MAXMB="${1:-5}" ;;
    --top) shift; TOP="${1:-10}" ;; --dirs) shift; DIRS="${1:-10}" ;; --summary) SUMMARY=1 ;;
    -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]:-$0}" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "afx-bloat-check: unknown option $1" >&2; exit 2 ;;
    *) REPO="$1" ;;
  esac; shift
done
REPO="${REPO:-$PWD}"
[ -d "$REPO" ] || { echo "afx-bloat-check: not a directory: $REPO" >&2; exit 2; }
unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_PREFIX 2>/dev/null || true
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "afx-bloat-check: not a git repo: $REPO" >&2; exit 2; }
git -C "$REPO" rev-parse --verify -q "$REF^{commit}" >/dev/null || { echo "afx-bloat-check: unknown ref $REF" >&2; exit 2; }
TMP="$(mktemp)"; trap 'rm -f "$TMP" "$TMP.over"' EXIT
# size<TAB>path, one per blob (submodules/commits skipped)
git -C "$REPO" ls-tree -r -l "$REF" 2>/dev/null | awk -F'\t' '{ n=split($1,a," +"); if (a[2]=="blob") printf "%s\t%s\n", a[n], $2 }' > "$TMP"
TRACKED="$(awk -F'\t' '{s+=$1} END{printf "%d", s+0}' "$TMP")"
# object store size in KiB (pack + loose), from count-objects -v
KIB="$(git -C "$REPO" count-objects -v 2>/dev/null | awk '/^(size|size-pack):/{s+=$2} END{print s+0}')"
MAXB=$((MAXMB * 1048576))
allowed() { # allowed <path>
  [ -f "$REPO/.afx-bloat-allow" ] || return 1
  local line pat
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$line" ] || continue
    pat="$line"; case "$1" in $pat) return 0 ;; esac
  done < "$REPO/.afx-bloat-allow"
  return 1
}
: > "$TMP.over"; OVER=0; ALLOWED=0
while IFS="$(printf '\t')" read -r sz p; do
  [ "$sz" -gt "$MAXB" ] 2>/dev/null || continue
  if allowed "$p"; then ALLOWED=$((ALLOWED+1)); printf 'ALLOWED\t%s\t%s\n' "$sz" "$p" >> "$TMP.over"
  else OVER=$((OVER+1)); printf 'OVER\t%s\t%s\n' "$sz" "$p" >> "$TMP.over"; fi
done < <(sort -t"$(printf '\t')" -k1,1nr "$TMP")
LARGEST="$(sort -t"$(printf '\t')" -k1,1nr "$TMP" | head -1)"
LSZ="${LARGEST%%	*}"; LP="${LARGEST#*	}"; LSZ="${LSZ:-0}"
mb() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1048576}'; }
if [ "$SUMMARY" = 1 ]; then
  echo "OVER=$OVER (limit ${MAXMB}MB, allowed=$ALLOWED) largest=$(mb "$LSZ")MB ${LP:--} pack=$(awk -v k="$KIB" 'BEGIN{printf "%.0f", k/1024}')MiB tracked=$(mb "$TRACKED")MB"
  exit 0
fi
echo "afx-bloat-check $(cd "$REPO" && pwd -P)  ref=$REF"
echo "git object store : $(awk -v k="$KIB" 'BEGIN{printf "%.1f MiB", k/1024}')"
echo "tracked at ref   : $(mb "$TRACKED") MB in $(wc -l < "$TMP" | tr -d ' ') files"
echo "-- top $TOP tracked files (MB)"
sort -t"$(printf '\t')" -k1,1nr "$TMP" | head -"$TOP" | awk -F'\t' '{printf "%8.1f  %s\n", $1/1048576, $2}'
echo "-- top $DIRS directories by tracked bytes, depth 2 (MB)"
awk -F'\t' '{ n=split($2,p,"/"); k=(n>=3)? p[1] "/" p[2] : (n==2? p[1] "/" : "(root)"); s[k]+=$1 } END{for(k in s) printf "%d\t%s\n", s[k], k}' "$TMP" \
  | sort -t"$(printf '\t')" -k1,1nr | head -"$DIRS" | awk -F'\t' '{printf "%8.1f  %s\n", $1/1048576, $2}'
echo "-- files over ${MAXMB} MB: OVER=$OVER ALLOWED=$ALLOWED (advisory; allow list: .afx-bloat-allow)"
awk -F'\t' '{printf "%s %8.1f MB  %s\n", $1, $2/1048576, $3}' "$TMP.over" | head -40
[ "$OVER" -gt 40 ] && echo "... $((OVER+ALLOWED-40)) more"
exit 0
