#!/bin/sh
# Installs smith, the Forgejo CLI: the latest release by default.
#
#   curl -fsSL https://raw.githubusercontent.com/Arzaroth/smith/master/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/Arzaroth/smith/master/install.sh | sh -s -- --dev
#
# Run with --help for the options. Everything runs from `main` on the last
# line, so a download cut short runs nothing.
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
  --from FORGE     Download from github (default) or forgejo (git.arzaroth.com,
                   releases from 0.3.0 on)
  -h, --help       Show this help

To uninstall, delete the binary; smith keeps its settings in
~/.config/smith and its tokens in the system keyring (`smith auth logout`).
EOF
}

say() { printf '%s\n' "$*" >&2; }
die() {
  say "install.sh: $*"
  exit 1
}

# Downloads over https only, redirects included; SMITH_INSTALL_URL (the
# installer's own tests) may point at file://.
fetch() {
  if [ "$downloader" = curl ]; then
    curl -fsL --proto "$protocols" --proto-redir "$protocols" --tlsv1.2 "$@"
  else
    header=""
    if [ "$1" = -H ]; then
      header="$2"
      shift 2
    fi
    wget -q --https-only ${header:+--header="$header"} -O- "$1"
  fi
}

fetch_to() {
  if [ "$downloader" = curl ]; then
    if [ -t 2 ]; then
      curl -f --progress-bar -L --proto "$protocols" --proto-redir "$protocols" --tlsv1.2 -o "$2" "$1"
    else
      curl -fsL --proto "$protocols" --proto-redir "$protocols" --tlsv1.2 -o "$2" "$1"
    fi
  else
    wget -q --https-only -O "$2" "$1"
  fi
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

is_version() {
  case "$1" in
    "" | *[!0-9.]* | .* | *. | *..*) return 1 ;;
  esac
  [ "$(printf '%s' "$1" | tr -cd . | wc -c | tr -d ' ')" = 2 ]
}

latest() {
  if [ -n "${SMITH_INSTALL_URL:-}" ]; then
    tag=""
  elif [ "$from" = github ] && [ "$downloader" = curl ]; then
    url="$(curl -fsIL --proto "$protocols" --proto-redir "$protocols" -o /dev/null -w '%{url_effective}' "$web/releases/latest" || true)"
    tag="${url##*/}"
  elif [ "$from" = github ]; then
    tag="$(fetch "https://api.github.com/repos/$repo/releases/latest" | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1 || true)"
  else
    tag="$(fetch "https://git.arzaroth.com/api/v1/repos/$repo/releases/latest" | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' || true)"
  fi
  is_version "${tag#v}" || die "cannot find the latest release on $web/releases${hint_github_api}"
  printf '%s\n' "${tag#v}"
}

install_release() {
  [ -n "$version" ] || version="$(latest)"
  if [ -x "$dir/smith" ] && [ "$("$dir/smith" --version 2>/dev/null </dev/null || true)" = "smith $version" ]; then
    say "smith $version is already installed in $dir"
    exit 0
  fi
  target="$arch-$os"
  [ "$os" = linux ] && target="$target-musl"
  name="smith-$version-$target"
  base="$web/releases/download/v$version"
  say "Downloading smith $version for $target from $from"
  if ! fetch_to "$base/SHA256SUMS" "$tmp/SHA256SUMS"; then
    if [ "$from" = forgejo ]; then
      die "no release v$version on $web/releases (Forgejo has releases from 0.3.0 on; try --from github)"
    fi
    die "no release v$version on $web/releases"
  fi
  want="$(awk -v n="$name.tar.gz" '$2 == n || $2 == "*" n { print $1 }' "$tmp/SHA256SUMS")"
  [ -n "$want" ] || die "release v$version has no build for $target"
  fetch_to "$base/$name.tar.gz" "$tmp/$name.tar.gz" || die "cannot download $name.tar.gz from release v$version"
  [ "$(sha256 "$tmp/$name.tar.gz")" = "$want" ] || die "$name.tar.gz does not match the release's SHA256SUMS; try again"
  tar -xzf "$tmp/$name.tar.gz" -C "$tmp" </dev/null
  binary="$tmp/$name/smith"
  [ -f "$binary" ] || die "$name.tar.gz holds no smith binary"
}

# Sets zig_mode and zig_bin: Zig $zig_version from PATH, through mise, or
# downloaded into $tmp and checked against ziglang.org's checksums.
find_zig() {
  zig_mode="path"
  zig_bin="zig"
  if command -v zig >/dev/null 2>&1 && [ "$(zig version </dev/null)" = "$zig_version" ]; then
    return
  fi
  if command -v mise >/dev/null 2>&1; then
    zig_mode="mise"
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
  fetch_to "https://ziglang.org/download/$zig_version/$zig.tar.xz" "$tmp/$zig.tar.xz" || die "cannot download Zig $zig_version from ziglang.org"
  [ "$(sha256 "$tmp/$zig.tar.xz")" = "$sum" ] || die "$zig.tar.xz does not match its pinned checksum"
  tar -xJf "$tmp/$zig.tar.xz" -C "$tmp" </dev/null || die "cannot unpack $zig.tar.xz (is xz installed?)"
  zig_bin="$tmp/$zig/zig"
}

run_zig() {
  if [ "$zig_mode" = mise ]; then
    mise exec "zig@$zig_version" -- zig "$@" </dev/null
  else
    "$zig_bin" "$@" </dev/null
  fi
}

install_dev() {
  if [ "$from" = github ]; then
    sha="$(fetch -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/$repo/commits/master" || true)"
  else
    sha="$(fetch "https://git.arzaroth.com/api/v1/repos/$repo/branches/master" | sed -n 's/.*"commit":{"id":"\([0-9a-f]*\)".*/\1/p' || true)"
  fi
  case "$sha" in
    *[!0-9a-f]* | "") die "cannot find the tip of master on $web${hint_github_api}" ;;
  esac
  [ "${#sha}" = 40 ] || die "cannot find the tip of master on $web"
  short="$(printf '%.7s' "$sha")"
  say "Downloading smith at master ($short) from $from"
  fetch_to "$web/archive/$sha.tar.gz" "$tmp/source.tar.gz" || die "cannot download the source of $short"
  mkdir "$tmp/source"
  tar -xzf "$tmp/source.tar.gz" -C "$tmp/source" </dev/null
  src="$(find "$tmp/source" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [ -f "$src/build.zig" ] || die "the source of $short has no build.zig"
  current="$(sed -n 's/^    \.version = "\([^"]*\)",$/\1/p' "$src/build.zig.zon")"
  find_zig
  say "Building smith $current-dev+$short"
  (cd "$src" && run_zig build -Doptimize=ReleaseSafe "-Dversion=$current-dev+$short" --prefix "$tmp/out") ||
    die "the build failed"
  binary="$tmp/out/bin/smith"
}

main() {
  version=""
  dev=0
  dir="${SMITH_INSTALL_DIR:-}"
  from="github"
  while [ $# -gt 0 ]; do
    case "$1" in
      --version | --dir | --from)
        [ $# -ge 2 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ] || die "$1 needs a value"
        value="$2"
        flag="$1"
        shift 2
        ;;
      --version=* | --dir=* | --from=*)
        flag="${1%%=*}"
        value="${1#*=}"
        [ -n "$value" ] || die "$flag needs a value"
        shift
        ;;
      --dev) dev=1; shift; continue ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown option $1 (see --help)" ;;
    esac
    case "$flag" in
      --version) version="${value#v}"; is_version "$version" || die "--version takes X.Y.Z, not $value" ;;
      --dir) dir="$value" ;;
      --from) from="$value" ;;
    esac
  done
  [ "$dev" = 1 ] && [ -n "$version" ] && die "choose --version or --dev, not both"
  [ -n "$dir" ] || dir="${HOME:?set HOME or pass --dir}/.local/bin"
  case "$dir" in
    \~) dir="$HOME" ;;
    \~/*) dir="$HOME/${dir#\~/}" ;;
  esac

  protocols="=https"
  hint_github_api=""
  case "$from" in
    github)
      web="https://github.com/$repo"
      hint_github_api=" (GitHub may be rate-limiting this address; try again later or pass --from forgejo)"
      ;;
    forgejo) web="https://git.arzaroth.com/$repo" ;;
    *) die "--from must be github or forgejo" ;;
  esac
  if [ -n "${SMITH_INSTALL_URL:-}" ]; then
    web="$SMITH_INSTALL_URL"
    protocols="=https,file"
  fi

  if command -v curl >/dev/null 2>&1; then
    downloader=curl
  elif command -v wget >/dev/null 2>&1; then
    downloader=wget
  else
    die "needs curl or wget"
  fi
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 ||
    die "needs sha256sum or shasum to check the download"
  command -v tar >/dev/null 2>&1 || die "needs tar"

  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="macos" ;;
    *) die "no build for $(uname -s): smith is released for Linux and macOS; build it from source (see the README)" ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch="x86_64" ;;
    aarch64 | arm64) arch="aarch64" ;;
    *) die "no build for $(uname -m): smith is released for x86_64 and aarch64; build it from source (see the README)" ;;
  esac

  tmp="$(mktemp -d)"
  staged=""
  trap 'rm -rf "$tmp"; [ -z "$staged" ] || rm -f "$staged"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if [ "$dev" = 1 ]; then install_dev; else install_release; fi

  mkdir -p "$dir"
  dir="$(cd "$dir" && pwd)"
  before=""
  [ -x "$dir/smith" ] && before="$("$dir/smith" --version 2>/dev/null </dev/null || true)"
  staged="$(mktemp "$dir/.smith.XXXXXX")"
  cp "$binary" "$staged"
  chmod 755 "$staged"
  mv -f "$staged" "$dir/smith"
  staged=""
  now="$("$dir/smith" --version 2>/dev/null </dev/null || echo "smith (unknown version)")"
  if [ -n "$before" ]; then
    say "Replaced smith ${before#smith } with ${now#smith } in $dir"
  else
    say "Installed $now to $dir/smith"
  fi

  case ":${PATH:-}:" in
    *":$dir:"*)
      found="$(command -v smith 2>/dev/null || true)"
      if [ -n "$found" ] && [ "$found" != "$dir/smith" ]; then
        say "! $found comes first on your PATH and will run instead"
      fi
      ;;
    *)
      case "${SHELL:-}" in
        */fish) say "! $dir is not on your PATH; add it with: fish_add_path $dir" ;;
        *) say "! $dir is not on your PATH; add it to your shell profile: export PATH=\"$dir:\$PATH\"" ;;
      esac
      ;;
  esac
  if [ -z "$before" ]; then
    say "Next: smith auth login --hostname <your-forgejo-host>"
    say "Shell completion: smith completion bash|zsh|fish; an agent skill: smith help skill"
  fi
}

main "$@"
