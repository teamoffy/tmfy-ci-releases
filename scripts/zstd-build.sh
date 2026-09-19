#!/bin/sh
# Build zstd shared/static libs, smoke-test, and pack a tar.zst rooted at
# opt/zstd (extract at / to install).
# usage: zstd-build.sh <version>
# env:
#   ZSTD_PLATFORM        asset platform suffix, e.g. linux-x64 (required)
#   ZSTD_WORK            work dir (default .zstd-work)
#   ZSTD_UPSTREAM_SHA256 optional expected sha256 of the upstream source tarball
set -eu
version="${1:?usage: zstd-build.sh <version>}"
platform="${ZSTD_PLATFORM:?ZSTD_PLATFORM must be set (e.g. linux-x64)}"
work="${ZSTD_WORK:-$PWD/.zstd-work}"
out="$work/out"
prefix="$work/stage/opt/zstd"

case "$(uname -s)" in
Darwin) os=macos ;;
Linux) os=linux ;;
*) echo "zstd-build.sh: unsupported host $(uname -s)" >&2; exit 1 ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"
rm -rf "$work"
mkdir -p "$prefix" "$out"

# ------------------------------------------------------------------ toolchain
if [ "$os" = linux ]; then
	sudo apt-get update
	sudo apt-get install -y --no-install-recommends \
		build-essential cmake ninja-build lld zstd
	setup_linux_toolchain
else
	for f in cmake ninja zstd; do
		command -v "$f" >/dev/null 2>&1 || brew install "$f"
	done
fi

url="https://github.com/facebook/zstd/archive/refs/tags/v${version}.tar.gz"
tarball="$work/zstd-${version}.tar.gz"
fetch "$url" "$tarball" "${ZSTD_UPSTREAM_SHA256:-}"
upstream_sha=$(sha256_of "$tarball")
printf '%s\n' "$upstream_sha" >"$out/upstream-sha256.txt"
tar -xzf "$tarball" -C "$work"
src="$work/zstd-${version}/build/cmake"

case "$os" in
macos) extra_cmake="-DCMAKE_INSTALL_NAME_DIR=/opt/zstd/lib" ;;
*) extra_cmake="" ;;
esac
# shellcheck disable=SC2086
cmake -S "$src" -B "$work/build" -G Ninja \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$prefix" \
	-DCMAKE_INSTALL_LIBDIR=lib \
	-DZSTD_BUILD_SHARED=ON \
	-DZSTD_BUILD_STATIC=ON \
	-DZSTD_BUILD_PROGRAMS=ON \
	$extra_cmake
cmake --build "$work/build" --parallel "$(ncpu)"
cmake --install "$work/build"

# Smoke: roundtrip a buffer through the high-level API and check the version.
cat >"$work/smoke.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zstd.h>
int main(void) {
	const char *msg = "ci-releases";
	size_t cap = ZSTD_compressBound(strlen(msg));
	char *cbuf = malloc(cap);
	char *dbuf = malloc(strlen(msg) + 1);
	size_t clen = ZSTD_compress(cbuf, cap, msg, strlen(msg), 19);
	size_t dlen = ZSTD_decompress(dbuf, strlen(msg) + 1, cbuf, clen);
	int ok = clen > 0 && !ZSTD_isError(clen) && dlen == strlen(msg) &&
	         !ZSTD_isError(dlen) && memcmp(dbuf, msg, dlen) == 0;
	printf("%s\n", ZSTD_versionString());
	free(cbuf);
	free(dbuf);
	return ok ? 0 : 3;
}
EOF
${CC:-cc} -O2 -I"$prefix/include" "$work/smoke.c" \
	-L"$prefix/lib" -lzstd -Wl,-rpath,"$prefix/lib" \
	-o "$work/smoke"
if [ "$os" = macos ]; then
	# Staged dylibs carry /opt/zstd install names; repoint the smoke binary
	# at the staging dir.
	dep=$(otool -L "$work/smoke" | awk '/libzstd/ { print $1 }')
	if [ -n "$dep" ]; then
		install_name_tool -change "$dep" "$prefix/lib/$(basename -- "$dep")" "$work/smoke"
		codesign -f -s - "$work/smoke"
	fi
fi
smoke_out=$("$work/smoke")
echo "smoke: $smoke_out"
case "$smoke_out" in
"$version") ;;
*) echo "zstd-build.sh: smoke version mismatch: got '$smoke_out', want '$version'" >&2; exit 1 ;;
esac

{
	echo "product=zstd"
	echo "version=$version"
	echo "platform=$platform"
	echo "upstream-url=$url"
	echo "upstream-sha256=$upstream_sha"
	echo "flags=Release ZSTD_BUILD_SHARED=ON ZSTD_BUILD_STATIC=ON ZSTD_BUILD_PROGRAMS=ON"
	echo "cc=$(${CC:-cc} --version | head -n 1)"
	echo "cmake=$(cmake --version | head -n 1)"
	true
} >"$prefix/BUILD-INFO.txt"

asset="$out/zstd-${version}-${platform}.tar.zst"
sh "$script_dir/pack.sh" "$work/stage" "$asset" opt

# Re-extract the archive and re-check layout, links, and (macOS) signatures.
verify="$work/verify"
verify_extract "$asset" "$verify"
[ -f "$verify/opt/zstd/BUILD-INFO.txt" ] && [ -f "$verify/opt/zstd/include/zstd.h" ] || {
	echo "zstd-build.sh: packaged archive layout unexpected" >&2
	exit 1
}
if [ "$os" = macos ]; then
	for lib in "$verify"/opt/zstd/lib/*.dylib; do
		codesign --verify "$lib"
	done
else
	[ -e "$verify/opt/zstd/lib/libzstd.so" ] || {
		echo "zstd-build.sh: packaged archive is missing libzstd.so" >&2
		exit 1
	}
fi
echo "built $asset"
