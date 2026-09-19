#!/bin/sh
# Mirror official Bun release zips as tar.zst assets, keeping the zip layout
# (bun-<platform>/bun).
# usage: bun-repack.sh <version>
# env:
#   BUN_WORK       work dir (default .bun-work)
#   BUN_PLATFORMS  space-separated subset to build (default: all four)
set -eu
version="${1:?usage: bun-repack.sh <version>}"
work="${BUN_WORK:-$PWD/.bun-work}"
out="$work/out"
tag="bun-v${version}"
platforms="${BUN_PLATFORMS:-linux-x64 linux-aarch64 darwin-x64 darwin-aarch64}"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"
rm -rf "$work"
mkdir -p "$out" "$work/zips"

ensure_cmds unzip zstd # preinstalled on the runner images

shasums="$work/SHASUMS256.txt"
fetch "https://github.com/oven-sh/bun/releases/download/${tag}/SHASUMS256.txt" "$shasums"

for platform in $platforms; do
	name="bun-${platform}"
	zip="$work/zips/${name}.zip"
	fetch "https://github.com/oven-sh/bun/releases/download/${tag}/${name}.zip" "$zip"

	expected=$(awk -v n="${name}.zip" '$2 == n { print $1 }' "$shasums")
	actual=$(sha256_of "$zip")
	if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
		echo "bun-repack.sh: checksum mismatch for ${name}.zip: expected ${expected:-<missing>}, got $actual" >&2
		exit 1
	fi

	rm -rf "$work/stage"
	unzip -q "$zip" -d "$work/stage"
	[ -d "$work/stage/$name" ] || {
		echo "bun-repack.sh: $name.zip does not contain a top-level $name/ directory" >&2
		exit 1
	}

	asset="$out/bun-${version}-${platform}.tar.zst"
	sh "$script_dir/pack.sh" "$work/stage" "$asset" "$name"

	# Re-extract and confirm the repack preserved the upstream layout.
	verify="$work/verify"
	verify_extract "$asset" "$verify"
	[ -f "$verify/$name/bun" ] || {
		echo "bun-repack.sh: packaged archive is missing $name/bun" >&2
		exit 1
	}
	echo "mirrored $asset"
done
