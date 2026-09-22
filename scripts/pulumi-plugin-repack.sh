#!/bin/sh
# Repack one pulumi-plugins.txt provider for one platform: fetch the upstream
# release tarball, verify it against its GitHub asset digest, extract the
# pulumi-resource-<name> binary, stage it at usr/local/bin/, and pack a
# max-zstd tar.zst (extract at / to install into /usr/local/bin).
# usage: pulumi-plugin-repack.sh <name>   e.g. pulumi-plugin-repack.sh aws
# env:
#   PULUMI_PLUGIN_PLATFORM  house platform label (required):
#                           linux-x64 | linux-arm64 | darwin-arm64
#   PULUMI_PLUGIN_WORK      work dir (default .pulumi-plugin-work)
#   GH_TOKEN                GitHub token (asset digests come from the API)
set -eu
name="${1:?usage: pulumi-plugin-repack.sh <name>}"
platform="${PULUMI_PLUGIN_PLATFORM:?PULUMI_PLUGIN_PLATFORM must be set (linux-x64|linux-arm64|darwin-arm64)}"
work="${PULUMI_PLUGIN_WORK:-$PWD/.pulumi-plugin-work}"
out="$work/out"

case "$name" in '' | *[!a-z0-9-]*)
	echo "pulumi-plugin-repack.sh: invalid name '$name'" >&2
	exit 2 ;;
esac
case "$platform" in
linux-x64) upstream_os=linux; upstream_arch=amd64; want_arch='ELF 64-bit LSB.*x86-64' ;;
linux-arm64) upstream_os=linux; upstream_arch=arm64; want_arch='ELF 64-bit LSB.*aarch64' ;;
darwin-arm64) upstream_os=darwin; upstream_arch=arm64; want_arch='Mach-O 64-bit.*arm64' ;;
*)
	echo "pulumi-plugin-repack.sh: unsupported platform '$platform' (linux-x64|linux-arm64|darwin-arm64)" >&2
	exit 2 ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"

# <name> <version> <gh-repo> — comments/blank lines skipped.
version=
repo=
while read -r n v r _; do
	[ "$n" = "$name" ] || continue
	version=$v
	repo=$r
done <"$script_dir/pulumi-plugins.txt"
[ -n "$repo" ] || {
	echo "pulumi-plugin-repack.sh: '$name' is not in pulumi-plugins.txt" >&2
	exit 2
}

rm -rf "$work"
mkdir -p "$out" "$work/dl"
export UPSTREAM_SHA_LOG="$work/upstream-sha256.txt"
: >"$UPSTREAM_SHA_LOG"

member="pulumi-resource-$name"
tarball="$member-v$version-$upstream_os-$upstream_arch.tar.gz"
url="https://github.com/$repo/releases/download/v$version/$tarball"

ensure_cmds gh jq
release_json="$work/release.json"
gh api "repos/$repo/releases/tags/v$version" >"$release_json" || {
	echo "pulumi-plugin-repack.sh: no upstream release $repo v$version" >&2
	exit 1
}
sha=$(jq -r --arg asset "$tarball" \
	'.assets[] | select(.name == $asset) | .digest // empty' \
	"$release_json" | sed 's/^sha256://')
[ -n "$sha" ] || {
	echo "pulumi-plugin-repack.sh: no GitHub asset digest for $tarball" >&2
	exit 1
}
fetch "$url" "$work/dl/$tarball" "$sha"

stage="$work/stage"
mkdir -p "$stage/usr/local/bin" "$work/x"
tar -xzf "$work/dl/$tarball" -C "$work/x"
found=$(find "$work/x" -type f -name "$member" | head -n 1)
[ -n "$found" ] || {
	echo "pulumi-plugin-repack.sh: no member '$member' in $tarball" >&2
	exit 1
}
install -m 0755 "$found" "$stage/usr/local/bin/$member"
rm -rf "$work/x"

# The staged binary must be the requested platform's arch — an os/arch mapping
# bug would otherwise publish a valid binary of the wrong arch.
ensure_cmds file
file_desc=$(file -b "$stage/usr/local/bin/$member")
printf '%s\n' "$file_desc" | grep -Eq "$want_arch" || {
	echo "pulumi-plugin-repack.sh: $platform binary is not the expected arch: $file_desc" >&2
	exit 1
}

asset="$out/pulumi-plugin-$name-$version-$platform.tar.zst"
sh "$script_dir/pack.sh" "$stage" "$asset" usr

# Re-extract the archive and re-check the layout.
verify="$work/verify"
verify_extract "$asset" "$verify"
[ -x "$verify/usr/local/bin/$member" ] || {
	echo "pulumi-plugin-repack.sh: packaged archive is missing usr/local/bin/$member" >&2
	exit 1
}
mv "$UPSTREAM_SHA_LOG" "$out/upstream-sha256-$platform.txt"
echo "built $asset"
