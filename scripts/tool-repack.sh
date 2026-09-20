#!/bin/sh
# Repack one ci-tools.txt entry: fetch the upstream file(s), verify them
# against upstream-authenticated checksums, stage the install layout, and pack
# each arch as <name>-<version>-linux-<arch>.tar.zst.
#
# Verification: github.com release downloads are checked against the asset's
# GitHub-recorded sha256 digest; other URLs against a <url>.sha256 or
# <url>.sha256sum sidecar. A tool with neither fails the build — mirrors here
# are verified, matching the pins tea keeps in downloads.sha256.
#
# usage: tool-repack.sh <name> <tag>     e.g. kubectl v1.37.0
# env:
#   CI_TOOLS_WORK   work dir (default .ci-tools-work)
#   GH_TOKEN        required when any URL is a github.com release asset
set -eu
name="${1:?usage: tool-repack.sh <name> <tag>}"
tag="${2:?usage: tool-repack.sh <name> <tag>}"
work="${CI_TOOLS_WORK:-$PWD/.ci-tools-work}"
out="$work/out"
ver="${tag#v}"

case "$name" in '' | *[!a-z0-9-]*)
	echo "tool-repack.sh: invalid name '$name'" >&2
	exit 2 ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"

# name repo url-x64 url-arm64 mode — comments/blank lines skipped.
repo=
url_x64=
url_arm64=
mode=
while read -r n r u64 ua64 m _; do
	[ "$n" = "$name" ] || continue
	repo=$r; url_x64=$u64; url_arm64=$ua64; mode=$m
done <"$script_dir/ci-tools.txt"
[ -n "$repo" ] || {
	echo "tool-repack.sh: '$name' is not in ci-tools.txt" >&2
	exit 2
}
case "$mode" in
bin | tardir | tarbin:*) ;;
*)
	echo "tool-repack.sh: '$name' has unknown mode '$mode'" >&2
	exit 2 ;;
esac

rm -rf "$work"
mkdir -p "$out" "$work/dl"
export UPSTREAM_SHA_LOG="$work/upstream-sha256.txt"
: >"$UPSTREAM_SHA_LOG"

expand() { # <url-template> -> url with {tag}/{ver} substituted
	printf '%s' "$1" | sed -e "s|{tag}|$tag|g" -e "s|{ver}|$ver|g"
}

# GitHub asset digests, fetched once when the row uses github.com downloads.
release_json=
case "$url_x64$url_arm64" in
*github.com*)
	ensure_cmds gh jq
	release_json="$work/release.json"
	gh api "repos/$repo/releases/tags/$tag" >"$release_json" ;;
esac

expected_sha() { # <url> <basename> -> upstream sha256 (required)
	case "$1" in
	https://github.com/*/releases/download/*)
		jq -r --arg asset "$2" \
			'.assets[] | select(.name == $asset) | .digest // empty' \
			"$release_json" | sed 's/^sha256://' ;;
	*)
		for suffix in .sha256 .sha256sum; do
			if side=$(curl -fsSL --retry 3 --max-time 20 "$1$suffix" 2>/dev/null); then
				printf '%s\n' "$side" | awk '{print $1; exit}'
				return 0
			fi
		done
		printf '\n' ;;
	esac
}

for spec in "linux-x64 $url_x64" "linux-arm64 $url_arm64"; do
	# shellcheck disable=SC2086 # word-splitting intended
	set -- $spec
	platform=$1
	url=$(expand "$2")
	[ "$url" != - ] || continue
	file="$work/dl/${platform}-${url##*/}"
	sha=$(expected_sha "$url" "${url##*/}")
	[ -n "$sha" ] || {
		echo "tool-repack.sh: no upstream checksum for $url" >&2
		exit 1
	}
	fetch "$url" "$file" "$sha"

	stage="$work/stage-$platform"
	rm -rf "$stage"
	case "$mode" in
	bin)
		mkdir -p "$stage/usr/local/bin"
		install -m 0755 "$file" "$stage/usr/local/bin/$name"
		entry=usr ;;
	tarbin:*)
		member=${mode#tarbin:}
		mkdir -p "$stage/usr/local/bin" "$work/x"
		tar -xzf "$file" -C "$work/x"
		found=$(find "$work/x" -type f -name "$member" | head -n 1)
		[ -n "$found" ] || {
			echo "tool-repack.sh: no member '$member' in $url" >&2
			exit 1
		}
		install -m 0755 "$found" "$stage/usr/local/bin/$member"
		rm -rf "$work/x"
		entry=usr ;;
	tardir)
		mkdir -p "$work/x" "$stage/opt/$name"
		tar -xzf "$file" -C "$work/x"
		# Archives either nest everything under one top dir or are flat.
		src_dir=$work/x
		count=0
		only=
		for d in "$work/x"/* "$work/x"/.[!.]*; do
			[ -e "$d" ] || continue
			count=$((count + 1))
			only=$d
		done
		[ "$count" -eq 1 ] && [ -d "$only" ] && src_dir=$only
		cp -a "$src_dir/." "$stage/opt/$name/"
		rm -rf "$work/x"
		entry=opt ;;
	esac

	asset="$out/$name-$ver-$platform.tar.zst"
	sh "$script_dir/pack.sh" "$stage" "$asset" "$entry"
	verify_extract "$asset" "$work/verify-$platform"
	case "$mode" in
	bin) probe="$work/verify-$platform/usr/local/bin/$name" ;;
	tarbin:*) probe="$work/verify-$platform/usr/local/bin/${mode#tarbin:}" ;;
	tardir) probe="$work/verify-$platform/opt/$name" ;;
	esac
	[ -e "$probe" ] || {
		echo "tool-repack.sh: packaged archive is missing ${probe#"$work/verify-$platform/"}" >&2
		exit 1
	}
	echo "mirrored $url -> $asset"
done

cat >"$out/release-info.env" <<EOF
NAME=$name
VERSION=$ver
TAG=$tag
REPO=$repo
MODE=$mode
EOF
mv "$UPSTREAM_SHA_LOG" "$out/upstream-sha256.txt"
echo "mirrored $name $tag"
