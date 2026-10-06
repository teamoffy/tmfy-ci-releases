#!/bin/sh
# Repack one Adoptium Temurin (OpenJDK) artifact as a tar.zst asset with a
# `home/` root — consumers extract at <dest> so <dest>/home is the JDK home.
# The macOS bundle's Contents/Home nesting is flattened to the same `home/`
# contract, so every platform's repack carries bin/java at home/bin/java.
#
# Download URL + sha256 come from check.sh's Adoptium v3 API resolution (the
# API's own checksum field). The download is verified against that checksum
# and cross-checked against the upstream .sha256.txt sidecar the checksum
# link points at — a moved/replaced artifact fails either check.
#
# usage: openjdk-repack.sh <version> <platform> <url> <sha256> <checksum-url>
#        platform: linux-x64 | linux-arm64 | darwin-arm64
# env:
#   OPENJDK_WORK       work dir (default .openjdk-work)
set -eu
version="${1:?usage: openjdk-repack.sh <version> <platform> <url> <sha256> <checksum-url>}"
platform="${2:?usage: openjdk-repack.sh <version> <platform> <url> <sha256> <checksum-url>}"
url="${3:?usage: openjdk-repack.sh <version> <platform> <url> <sha256> <checksum-url>}"
pin="${4:?usage: openjdk-repack.sh <version> <platform> <url> <sha256> <checksum-url>}"
sum_url="${5:?usage: openjdk-repack.sh <version> <platform> <url> <sha256> <checksum-url>}"
work="${OPENJDK_WORK:-$PWD/.openjdk-work}"
out="$work/out"

# Only Adoptium's own GitHub release assets are accepted, and only the JDK
# tarball matching the platform.
case "$platform:$url" in
linux-x64:https://github.com/adoptium/temurin*-binaries/releases/download/*/OpenJDK*U-jdk_x64_linux_hotspot_*.tar.gz | \
linux-arm64:https://github.com/adoptium/temurin*-binaries/releases/download/*/OpenJDK*U-jdk_aarch64_linux_hotspot_*.tar.gz | \
darwin-arm64:https://github.com/adoptium/temurin*-binaries/releases/download/*/OpenJDK*U-jdk_aarch64_mac_hotspot_*.tar.gz) ;;
*)
	echo "openjdk-repack.sh: unexpected artifact URL for '$platform': $url" >&2
	exit 2 ;;
esac
printf '%s\n' "$pin" | grep -Eq '^[0-9a-f]{64}$' || {
	echo "openjdk-repack.sh: malformed sha256 '$pin'" >&2
	exit 2
}
case "$sum_url" in
https://github.com/adoptium/temurin*-binaries/releases/download/*) ;;
*)
	echo "openjdk-repack.sh: unexpected checksum URL: $sum_url" >&2
	exit 2 ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"

rm -rf "$work"
mkdir -p "$out" "$work/dl"
ensure_cmds curl zstd # preinstalled on the runner images

tgz="$work/dl/openjdk-${platform}.tar.gz"
curl -fsSL --retry 3 -o "$tgz" "$url"
check_sha "$tgz" "$pin"
# The published .sha256.txt sidecar must agree with the API checksum.
side=$(curl -fsSL --retry 3 "$sum_url" | awk '{ print $1; exit }')
if [ "$side" != "$pin" ]; then
	echo "openjdk-repack.sh: $sum_url says $side, not the API checksum $pin for $platform" >&2
	exit 1
fi
if [ -n "${UPSTREAM_SHA_LOG:-}" ]; then
	echo "$(sha256_of "$tgz")  $(basename "$url")" >>"$UPSTREAM_SHA_LOG"
fi

# The bundle extracts to a single top dir (macOS nests the real JDK home one
# level deeper at Contents/Home) — find the dir holding bin/java and restage
# it as `home/`.
rm -rf "$work/extract" "$work/stage"
mkdir -p "$work/extract" "$work/stage"
tar -xzf "$tgz" -C "$work/extract"
top=
for candidate in "$work/extract"/*/ "$work/extract"/*/Contents/Home/; do
	if [ -x "$candidate/bin/java" ]; then
		top=${candidate%/}
		break
	fi
done
[ -n "$top" ] || {
	echo "openjdk-repack.sh: no JDK home (bin/java) in the $platform bundle" >&2
	exit 1
}
mv "$top" "$work/stage/home"

asset="$out/openjdk-${version}-${platform}.tar.zst"
sh "$script_dir/pack.sh" "$work/stage" "$asset" home

verify="$work/verify"
verify_extract "$asset" "$verify"
[ -x "$verify/home/bin/java" ] || {
	echo "openjdk-repack.sh: repack of $platform lost home/bin/java" >&2
	exit 1
}
echo "openjdk $version $platform -> $asset"
