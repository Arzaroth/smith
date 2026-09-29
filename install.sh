#!/bin/sh
# Installs smith, the Forgejo CLI: the latest release by default.
#
#   curl -fsSL https://raw.githubusercontent.com/Arzaroth/smith/master/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/Arzaroth/smith/master/install.sh | sh -s -- --dev
#
# Run with --help for the options.
set -eu

repo="Arzaroth/smith"
zig_version="0.16.0"

usage() {
  cat <<'EOF'
Install smith, the Forgejo CLI.

Usage: install.sh [--version X.Y.Z | --dev] [--dir DIR] [--from github|forgejo]

  --version X.Y.Z  Install that release instead of the latest one
  --dev            Build the tip of master from source, with Zig 0.16.0: the
                   one on PATH, else mise's, else a checked download
  --dir DIR        Where to put the binary (default: $SMITH_INSTALL_DIR, or
                   ~/.local/bin)
  --from FORGE     Download from github (default) or forgejo (git.arzaroth.com)
  -h, --help       Show this help
EOF
}

say() { printf '%s\n' "$*" >&2; }
die() {
  say "install.sh: $*"
  exit 1
}

version=""
dev=0
dir="${SMITH_INSTALL_DIR:-${HOME:?}/.local/bin}"
from="github"
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs a value"; version="${2#v}"; shift 2 ;;
    --version=*) version="${1#--version=}"; version="${version#v}"; shift ;;
    --dev) dev=1; shift ;;
    --dir) [ $# -ge 2 ] || die "--dir needs a value"; dir="$2"; shift 2 ;;
    --dir=*) dir="${1#--dir=}"; shift ;;
    --from) [ $# -ge 2 ] || die "--from needs a value"; from="$2"; shift 2 ;;
    --from=*) from="${1#--from=}"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done
[ "$dev" = 1 ] && [ -n "$version" ] && die "choose --version or --dev, not both"

case "$from" in
  github) web="https://github.com/$repo" ;;
  forgejo) web="https://git.arzaroth.com/$repo" ;;
  *) die "--from must be github or forgejo" ;;
esac

if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL "$@"; }
  fetch_to() { curl -fsSL -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() {
    header=""
    if [ "$1" = -H ]; then header="$2"; shift 2; fi
    wget -qO- ${header:+--header="$header"} "$1"
  }
  fetch_to() { wget -qO "$2" "$1"; }
else
  die "needs curl or wget"
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  die "needs sha256sum or shasum to check the download"
fi

case "$(uname -s)" in
  Linux) os="linux" ;;
  Darwin) os="macos" ;;
  *) die "no build for $(uname -s); smith is released for Linux and macOS" ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch="x86_64" ;;
  aarch64 | arm64) arch="aarch64" ;;
  *) die "no build for $(uname -m); smith is released for x86_64 and aarch64" ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

latest() {
  if [ "$from" = github ] && command -v curl >/dev/null 2>&1; then
    url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$web/releases/latest" 2>/dev/null || true)"
    tag="${url##*/}"
  elif [ "$from" = github ]; then
    tag="$(fetch "https://api.github.com/repos/$repo/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
  else
    tag="$(fetch "https://git.arzaroth.com/api/v1/repos/$repo/releases/latest" | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p')"
  fi
  case "$tag" in
    v[0-9]*) printf '%s\n' "${tag#v}" ;;
    *) die "cannot find the latest release on $web/releases" ;;
  esac
}

install_release() {
  [ -n "$version" ] || version="$(latest)"
  target="$arch-$os"
  [ "$os" = linux ] && target="$target-musl"
  name="smith-$version-$target"
  say "Downloading smith $version for $target from $from"
  fetch_to "$web/releases/download/v$version/$name.tar.gz" "$tmp/$name.tar.gz" ||
    die "no $name.tar.gz in release v$version"
  fetch_to "$web/releases/download/v$version/SHA256SUMS" "$tmp/SHA256SUMS" ||
    die "no SHA256SUMS in release v$version"
  want="$(sed -n "s/^\([0-9a-f]\{64\}\)  $name\.tar\.gz\$/\1/p" "$tmp/SHA256SUMS")"
  [ -n "$want" ] || die "SHA256SUMS does not list $name.tar.gz"
  [ "$(sha256 "$tmp/$name.tar.gz")" = "$want" ] || die "$name.tar.gz does not match SHA256SUMS"
  tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
  binary="$tmp/$name/smith"
}

# Prints the command that runs Zig $zig_version: the one on PATH, mise's, or
# one downloaded into $tmp and checked against ziglang.org's checksums.
zig_command() {
  if command -v zig >/dev/null 2>&1 && [ "$(zig version)" = "$zig_version" ]; then
    echo zig
    return
  fi
  if command -v mise >/dev/null 2>&1; then
    echo "mise exec zig@$zig_version -- zig"
    return
  fi
  case "$arch-$os" in
    x86_64-linux) sum="70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00" ;;
    aarch64-linux) sum="ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17" ;;
    x86_64-macos) sum="0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7" ;;
    aarch64-macos) sum="b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489" ;;
  esac
  zig="zig-$arch-$os-$zig_version"
  say "Downloading Zig $zig_version to build with"
  fetch_to "https://ziglang.org/download/$zig_version/$zig.tar.xz" "$tmp/$zig.tar.xz" || die "cannot download Zig $zig_version"
  [ "$(sha256 "$tmp/$zig.tar.xz")" = "$sum" ] || die "$zig.tar.xz does not match ziglang.org's checksum"
  tar -xJf "$tmp/$zig.tar.xz" -C "$tmp" || die "cannot unpack $zig.tar.xz (is xz installed?)"
  echo "$tmp/$zig/zig"
}

install_dev() {
  if [ "$from" = github ]; then
    sha="$(fetch -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/$repo/commits/master")"
  else
    sha="$(fetch "https://git.arzaroth.com/api/v1/repos/$repo/branches/master" | sed -n 's/.*"commit":{"id":"\([0-9a-f]*\)".*/\1/p')"
  fi
  case "$sha" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) die "cannot find the tip of master on $web" ;;
  esac
  short="$(printf '%.7s' "$sha")"
  say "Downloading smith at master ($short) from $from"
  fetch_to "$web/archive/$sha.tar.gz" "$tmp/source.tar.gz" || die "cannot download the source of $short"
  mkdir "$tmp/source"
  tar -xzf "$tmp/source.tar.gz" -C "$tmp/source"
  src="$(find "$tmp/source" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [ -f "$src/build.zig" ] || die "the source of $short has no build.zig"
  base="$(sed -n 's/^    \.version = "\([^"]*\)",$/\1/p' "$src/build.zig.zon")"
  zig="$(zig_command)"
  say "Building smith $base-dev+$short"
  # shellcheck disable=SC2086 # $zig may be a command with arguments
  (cd "$src" && $zig build -Doptimize=ReleaseSafe "-Dversion=$base-dev+$short" --prefix "$tmp/out") ||
    die "the build failed"
  binary="$tmp/out/bin/smith"
}

if [ "$dev" = 1 ]; then install_dev; else install_release; fi

mkdir -p "$dir"
cp "$binary" "$dir/.smith.new"
chmod 755 "$dir/.smith.new"
mv -f "$dir/.smith.new" "$dir/smith"
say "Installed $("$dir/smith" --version) to $dir/smith"

case ":${PATH:-}:" in
  *":$dir:"*) ;;
  *) say "! $dir is not on your PATH; add it, e.g. export PATH=\"$dir:\$PATH\"" ;;
esac
say "Next: smith auth login --hostname <your-forgejo-host>"
say "Shell completion: smith completion bash|zsh|fish; an agent skill: smith help skill"
