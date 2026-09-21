#!/bin/sh
# Repack Oracle GraalVM for JDK (GDS) artifacts as tar.zst assets with a
# `home/` root — consumers extract at <dest> so <dest>/home is the JDK home.
# The macOS bundle's Contents/Home nesting is flattened to the same `home/`
# contract, so every platform's repack carries bin/java at home/bin/java.
#
# Artifact ids + sha256 pins live in graalvm.txt (GDS has no "latest"). The
# download also cross-checks the object-storage opc-meta-content-sha256
# response header against the pin — a moved/replaced artifact fails either
# check.
#
# usage: graalvm-repack.sh <version>
# env:
#   GRAALVM_WORK       work dir (default .graalvm-work)
#   GRAALVM_PLATFORMS  space-separated subset to build (default: all rows)
set -eu
version="${1:?usage: graalvm-repack.sh <version>}"
work="${GRAALVM_WORK:-$PWD/.graalvm-work}"
out="$work/out"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"
manifest="$script_dir/graalvm.txt"

manifest_version=$(awk 'NF && $1 !~ /^#/ && $1 == "version" { print $2; exit }' "$manifest")
[ "$manifest_version" = "$version" ] || {
	echo "graalvm-repack.sh: graalvm.txt pins '$manifest_version', cannot build '$version'" >&2
	exit 1
}

platforms="${GRAALVM_PLATFORMS:-$(awk 'NF && $1 !~ /^#/ && $1 != "version" { print $1 }' "$manifest" | tr '\n' ' ')}"
rm -rf "$work"
mkdir -p "$out" "$work/dl"
ensure_cmds curl zstd # preinstalled on the runner images

for platform in $platforms; do
	row=$(awk -v p="$platform" 'NF && $1 !~ /^#/ && $1 == p { print $2, $3; found++ } END { if (found != 1) exit 1 }' "$manifest") || {
		echo "graalvm-repack.sh: expected exactly one graalvm.txt row for platform '$platform'" >&2
		exit 1
	}
	artifact=${row%% *}
	pin=${row##* }

	url="https://gds.oracle.com/api/20220101/artifacts/${artifact}/content"
	tgz="$work/dl/graalvm-${platform}.tar.gz"
	headers="$work/dl/graalvm-${platform}.headers"

	# GDS 302s to OCI object storage, which reports the object's sha256 in
	# opc-meta-content-sha256 — keep response headers for the cross-check.
	curl -fsSL --retry 3 -D "$headers" -o "$tgz" "$url"
	check_sha "$tgz" "$pin"
	meta=$(tr -d '\r' <"$headers" | awk 'tolower($1) == "opc-meta-content-sha256:" { print $2; exit }')
	if [ -n "$meta" ] && [ "$meta" != "$pin" ]; then
		echo "graalvm-repack.sh: opc-meta-content-sha256 $meta does not match the graalvm.txt pin $pin for $platform" >&2
		exit 1
	fi
	if [ -n "${UPSTREAM_SHA_LOG:-}" ]; then
		echo "$(sha256_of "$tgz")  graalvm-jdk-${version}_${platform}.tar.gz" >>"$UPSTREAM_SHA_LOG"
	fi

	# The bundle extracts to a single top dir (macOS nests the real JDK home
	# one level deeper at Contents/Home) — find the dir holding bin/java and
	# restage it as `home/`.
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
done
