#!/bin/sh
# Build zlib-ng shared libs, smoke-test, and pack a tar.zst rooted at
# opt/zlib-ng (extract at / to install).
# usage: zlib-ng-build.sh <version>
# env:
#   ZLIB_NG_PLATFORM        asset platform suffix, e.g. linux-x64 (required)
#   ZLIB_NG_WORK            work dir (default .zlib-ng-work)
#   ZLIB_NG_UPSTREAM_SHA256 optional expected sha256 of the upstream source tarball
set -eu
version="${1:?usage: zlib-ng-build.sh <version>}"
platform="${ZLIB_NG_PLATFORM:?ZLIB_NG_PLATFORM must be set (e.g. linux-x64)}"
work="${ZLIB_NG_WORK:-$PWD/.zlib-ng-work}"
out="$work/out"
prefix="$work/stage/opt/zlib-ng"

case "$(uname -s)" in
Darwin) os=macos ;;
Linux) os=linux ;;
*) echo "zlib-ng-build.sh: unsupported host $(uname -s)" >&2; exit 1 ;;
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

url="https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${version}.tar.gz"
tarball="$work/zlib-ng-${version}.tar.gz"
fetch "$url" "$tarball" "${ZLIB_NG_UPSTREAM_SHA256:-}"
upstream_sha=$(sha256_of "$tarball")
printf '%s\n' "$upstream_sha" >"$out/upstream-sha256.txt"
tar -xzf "$tarball" -C "$work"
src="$work/zlib-ng-${version}"

# Release build, shared libs; pin macOS dylib install names to /opt/zlib-ng/lib.
case "$os" in
macos) extra_cmake="-DCMAKE_INSTALL_NAME_DIR=/opt/zlib-ng/lib" ;;
*) extra_cmake="" ;;
esac
# shellcheck disable=SC2086
cmake -S "$src" -B "$work/build" -G Ninja \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$prefix" \
	-DBUILD_SHARED_LIBS=ON \
	-DZLIB_COMPAT=OFF \
	$extra_cmake
cmake --build "$work/build" --parallel "$(ncpu)"
cmake --install "$work/build"

# Smoke: link a tiny program against the installed lib and run it.
cat >"$work/smoke.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include <zlib-ng.h>
int main(void) {
	const char *v = zlibng_version();
	printf("%s\n", v);
	return strcmp(v, ZLIBNG_VERSION) == 0 ? 0 : 3;
}
EOF
${CC:-cc} -O2 -I"$prefix/include" "$work/smoke.c" \
	-L"$prefix/lib" -lz-ng -Wl,-rpath,"$prefix/lib" \
	-o "$work/smoke"
if [ "$os" = macos ]; then
	# Staged dylibs carry /opt/zlib-ng install names; repoint the smoke binary
	# at the staging dir.
	install_name_tool -change /opt/zlib-ng/lib/libz-ng.2.dylib \
		"$prefix/lib/libz-ng.2.dylib" "$work/smoke"
	codesign -f -s - "$work/smoke"
fi
smoke_out=$("$work/smoke")
echo "smoke: $smoke_out"
case "$smoke_out" in
"$version") ;;
*) echo "zlib-ng-build.sh: smoke version mismatch: got '$smoke_out', want '$version'" >&2; exit 1 ;;
esac

{
	echo "product=zlib-ng"
	echo "version=$version"
	echo "platform=$platform"
	echo "upstream-url=$url"
	echo "upstream-sha256=$upstream_sha"
	echo "flags=Release BUILD_SHARED_LIBS=ON ZLIB_COMPAT=OFF"
	echo "cc=$(${CC:-cc} --version | head -n 1)"
	echo "cmake=$(cmake --version | head -n 1)"
	true
} >"$prefix/BUILD-INFO.txt"

asset="$out/zlib-ng-${version}-${platform}.tar.zst"
sh "$script_dir/pack.sh" "$work/stage" "$asset" opt

# Re-extract the archive and re-check layout, links, and (macOS) signatures.
verify="$work/verify"
verify_extract "$asset" "$verify"
[ -f "$verify/opt/zlib-ng/BUILD-INFO.txt" ] || {
	echo "zlib-ng-build.sh: packaged archive is missing BUILD-INFO.txt" >&2
	exit 1
}
if [ "$os" = macos ]; then
	[ -e "$verify/opt/zlib-ng/lib/libz-ng.dylib" ] || {
		echo "zlib-ng-build.sh: packaged archive is missing libz-ng" >&2
		exit 1
	}
	for lib in "$verify"/opt/zlib-ng/lib/*.dylib; do
		codesign --verify "$lib"
	done
else
	[ -e "$verify/opt/zlib-ng/lib/libz-ng.so" ] || {
		echo "zlib-ng-build.sh: packaged archive is missing libz-ng" >&2
		exit 1
	}
fi
echo "built $asset"
