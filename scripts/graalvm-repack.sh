#!/bin/sh
# Repack one Oracle GraalVM for JDK (GDS) artifact as a tar.zst asset with a
# `home/` root — consumers extract at <dest> so <dest>/home is the JDK home.
# The macOS bundle's Contents/Home nesting is flattened to the same `home/`
# contract, so every platform's repack carries bin/java at home/bin/java.
#
# Artifact id + sha256 come from check.sh's GDS resolution (the API's own
# checksum field). The download also cross-checks the object-storage
# opc-meta-content-sha256 response header against that checksum — a
# moved/replaced artifact fails either check.
#
# usage: graalvm-repack.sh <version> <platform> <artifact-id> <sha256>
#        platform: linux-x64 | linux-arm64 | darwin-arm64
# env:
#   GRAALVM_WORK       work dir (default .graalvm-work)
set -eu
version="${1:?usage: graalvm-repack.sh <version> <platform> <artifact-id> <sha256>}"
platform="${2:?usage: graalvm-repack.sh <version> <platform> <artifact-id> <sha256>}"
artifact="${3:?usage: graalvm-repack.sh <version> <platform> <artifact-id> <sha256>}"
pin="${4:?usage: graalvm-repack.sh <version> <platform> <artifact-id> <sha256>}"
work="${GRAALVM_WORK:-$PWD/.graalvm-work}"
out="$work/out"

case "$platform" in
linux-x64 | linux-arm64 | darwin-arm64) ;;
*)
	echo "graalvm-repack.sh: unsupported platform '$platform' (linux-x64|linux-arm64|darwin-arm64)" >&2
	exit 2 ;;
esac
printf '%s\n' "$artifact" | grep -Eq '^[0-9A-F]{32}$' || {
	echo "graalvm-repack.sh: malformed GDS artifact id '$artifact'" >&2
	exit 2
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"

rm -rf "$work"
mkdir -p "$out" "$work/dl"
ensure_cmds curl zstd # preinstalled on the runner images

url="https://gds.oracle.com/api/20220101/artifacts/${artifact}/content"
tgz="$work/dl/graalvm-${platform}.tar.gz"
headers="$work/dl/graalvm-${platform}.headers"

# GDS 302s to OCI object storage, which reports the object's sha256 in
# opc-meta-content-sha256 — keep response headers for the cross-check.
curl -fsSL --retry 3 -D "$headers" -o "$tgz" "$url"
check_sha "$tgz" "$pin"
meta=$(tr -d '\r' <"$headers" | awk 'tolower($1) == "opc-meta-content-sha256:" { print $2; exit }')
if [ -n "$meta" ] && [ "$meta" != "$pin" ]; then
	echo "graalvm-repack.sh: opc-meta-content-sha256 $meta does not match the GDS checksum $pin for $platform" >&2
	exit 1
fi
if [ -n "${UPSTREAM_SHA_LOG:-}" ]; then
	echo "$(sha256_of "$tgz")  graalvm-jdk-${version}_${platform}.tar.gz" >>"$UPSTREAM_SHA_LOG"
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
	echo "graalvm-repack.sh: no JDK home (bin/java) in the $platform bundle" >&2
	exit 1
}
mv "$top" "$work/stage/home"

asset="$out/graalvm-${version}-${platform}.tar.zst"
sh "$script_dir/pack.sh" "$work/stage" "$asset" home

verify="$work/verify"
verify_extract "$asset" "$verify"
[ -x "$verify/home/bin/java" ] || {
	echo "graalvm-repack.sh: repack of $platform lost home/bin/java" >&2
	exit 1
}
echo "graalvm $version $platform -> $asset"
