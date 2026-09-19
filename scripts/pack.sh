#!/bin/sh
# Pack a directory into a max-compressed tar.zst and write a sha256 sidecar.
# usage: pack.sh <source-dir> <output.tar.zst> <tar-entry>
# The archive contains <tar-entry> (relative to <source-dir>) as its root.
set -eu
src="${1:?usage: pack.sh <source-dir> <output.tar.zst> <tar-entry>}"
out="${2:?usage: pack.sh <source-dir> <output.tar.zst> <tar-entry>}"
entry="${3:?usage: pack.sh <source-dir> <output.tar.zst> <tar-entry>}"

[ -d "$src/$entry" ] || {
	printf 'pack.sh: %s/%s is not a directory\n' "$src" "$entry" >&2
	exit 1
}
command -v zstd >/dev/null 2>&1 || {
	echo "pack.sh: zstd is required (apt-get install zstd / brew install zstd)" >&2
	exit 1
}
mkdir -p "$(dirname -- "$out")"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"

# zstd stays single-threaded (the default): -T0 splits the input into jobs and
# changes the bytes it emits for the same input. --long=27 is the largest window
# the zstd CLI and libzstd accept on decompression without an explicit
# --long/--memory flag, so `tar --zstd -xf` keeps working unconfigured.
#
# `sh` has no portable pipefail, so record tar's status out of band: zstd happily
# compresses a truncated stream and exits 0, which would ship a partial archive.
tar_status="$out.tar-status"
rm -f "$tar_status"
{ COPYFILE_DISABLE=1 tar -C "$src" -cf - "$entry" || echo "$?" >"$tar_status"; } |
	zstd --ultra -22 --long=27 -q -o "$out.tmp"
if [ -s "$tar_status" ]; then
	printf 'pack.sh: tar failed (exit %s) while archiving %s/%s\n' \
		"$(cat "$tar_status")" "$src" "$entry" >&2
	rm -f "$tar_status" "$out.tmp"
	exit 1
fi
rm -f "$tar_status"
mv "$out.tmp" "$out"

printf '%s  %s\n' "$(sha256_of "$out")" "$(basename -- "$out")" >"$out.sha256"
