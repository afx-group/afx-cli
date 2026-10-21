#!/bin/sh
# AFX CLI installer (POSIX sh). Installs a release of ${AFX_CLI_REPO:-afx-group/afx-cli} under ${AFX_HOME:-$HOME/.afx}.
#   AFX_CLI_VERSION  version to install (default: latest release)
#   AFX_HOME         install home (default: $HOME/.afx)
#   AFX_CLI_REPO     GitHub repo slug (default: afx-group/afx-cli)
# Test hooks: AFX_CLI_URL (file:// or https:// URL of the tarball), AFX_CLI_SHA256 (expected checksum).
# Never edits shell profiles.
set -eu

REPO="${AFX_CLI_REPO:-afx-group/afx-cli}"
AFX_HOME="${AFX_HOME:-$HOME/.afx}"

die() { echo "afx-install: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not found"; }

need tar
need bash
sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | sed 's/[[:space:]].*//'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | sed 's/[[:space:]].*//'
  else die "neither sha256sum nor shasum found: cannot verify the download, refusing to install"; fi
}
sha_of /dev/null >/dev/null   # fail early if there is no checksum tool

# fetch URL DEST: file:// is copied, anything else goes through curl.
fetch() {
  case "$1" in
    file://*)
      p="${1#file://}"
      case "$p" in /[A-Za-z]:*) p="${p#/}" ;; esac   # file:///C:/x on Windows
      [ -f "$p" ] || die "not found: $p"
      cp "$p" "$2" ;;
    *) need curl; curl -fsSL "$1" -o "$2" || die "download failed: $1" ;;
  esac
}

VERSION="${AFX_CLI_VERSION:-}"
URL="${AFX_CLI_URL:-}"
if [ -z "$VERSION" ] && [ -n "$URL" ]; then
  b="${URL##*/}"
  case "$b" in afx-cli-*.tar.gz) VERSION="${b#afx-cli-}"; VERSION="${VERSION%.tar.gz}" ;; *) VERSION="local" ;; esac
fi
if [ -z "$VERSION" ]; then
  need curl
  VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1) || true
  [ -n "$VERSION" ] || die "could not resolve the latest release of $REPO (set AFX_CLI_VERSION)"
fi
VERSION="${VERSION#v}"
case "$VERSION" in ""|*[!A-Za-z0-9._-]*) die "invalid version: $VERSION" ;; esac

[ -n "$URL" ] || URL="https://github.com/$REPO/releases/download/v$VERSION/afx-cli-$VERSION.tar.gz"

mkdir -p "$AFX_HOME/afx-cli"
WORK="$AFX_HOME/afx-cli/.tmp.$$"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT INT TERM

echo "afx-install: version $VERSION from $URL"
fetch "$URL" "$WORK/pkg.tar.gz"

WANT="${AFX_CLI_SHA256:-}"
if [ -z "$WANT" ]; then
  fetch "$URL.sha256" "$WORK/pkg.sha256"
  WANT=$(sed -n '1s/[[:space:]].*//p' "$WORK/pkg.sha256")
fi
GOT=$(sha_of "$WORK/pkg.tar.gz")
[ -n "$WANT" ] || die "no expected checksum available"
[ "$GOT" = "$WANT" ] || die "checksum mismatch (expected $WANT, got $GOT): nothing installed"
echo "afx-install: checksum ok ($GOT)"

mkdir -p "$WORK/x"
# relative paths: GNU tar reads "C:/..." as host:path
(cd "$WORK" && tar -xzf pkg.tar.gz -C x) || die "could not unpack the archive"
[ -f "$WORK/x/scripts/afx" ] || die "archive has no scripts/afx: not an AFX CLI release"

DEST="$AFX_HOME/afx-cli/$VERSION"
rm -rf "$DEST"
mv "$WORK/x" "$DEST"

# $AFX_HOME/afx-guard -> the version's scripts folder (symlink if possible, else a copy).
LINK="$AFX_HOME/afx-guard"
if [ -L "$LINK" ]; then rm -f "$LINK"
elif [ -e "$LINK" ]; then mv "$LINK" "$LINK.prev.$$" && echo "afx-install: previous $LINK kept at $LINK.prev.$$"; fi
if ln -s "$DEST/scripts" "$LINK" 2>/dev/null && [ -f "$LINK/afx" ]; then :
else rm -rf "$LINK"; cp -R "$DEST/scripts" "$LINK"; fi

mkdir -p "$AFX_HOME/bin"
cat > "$AFX_HOME/bin/afx" <<WRAP
#!/bin/sh
AFX_GUARD_DIR="$AFX_HOME/afx-guard"
export AFX_GUARD_DIR
exec bash "\$AFX_GUARD_DIR/afx" "\$@"
WRAP
chmod +x "$AFX_HOME/bin/afx"

echo "afx-install: installed $VERSION to $DEST"
echo
echo "Add this to your shell profile (it is not edited for you):"
echo "  export PATH=\"$AFX_HOME/bin:\$PATH\""
echo
echo "Next: afx init --org <your-org> --hub-repo <your-org>/<your-hub> --write"
