#!/bin/sh
# Build libgit2 + libssh2 (SSH provider, bundled into the prefix so the asset
# is self-contained — apt libgit2-dev minus the apt), smoke-test, and pack a
# tar.zst rooted at opt/libgit2. HTTPS: system OpenSSL on Linux, brew on macOS.
# usage: libgit2-build.sh <libgit2-version> <libssh2-version>
# env:
#   LIBGIT2_PLATFORM        asset platform suffix, e.g. linux-x64 (required)
#   LIBGIT2_WORK            work dir (default .libgit2-work)
#   LIBGIT2_UPSTREAM_SHA256 optional expected sha256 of the upstream source tarball
#   LIBSSH2_UPSTREAM_SHA256 optional expected sha256 of the bundled libssh2 tarball
set -eu
version="${1:?usage: libgit2-build.sh <libgit2-version> <libssh2-version>}"
libssh2_version="${2:?usage: libgit2-build.sh <libgit2-version> <libssh2-version>}"
platform="${LIBGIT2_PLATFORM:?LIBGIT2_PLATFORM must be set (e.g. linux-x64)}"
work="${LIBGIT2_WORK:-$PWD/.libgit2-work}"
out="$work/out"
prefix="$work/stage/opt/libgit2"

case "$(uname -s)" in
Darwin) os=macos ;;
Linux) os=linux ;;
*) echo "libgit2-build.sh: unsupported host $(uname -s)" >&2; exit 1 ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"
rm -rf "$work"
mkdir -p "$prefix" "$out"

if [ "$os" = linux ]; then
	sudo apt-get update
	sudo apt-get install -y --no-install-recommends \
		build-essential cmake lld libssl-dev ninja-build pkg-config zstd
	setup_linux_toolchain
else
	brew list --versions openssl@3 >/dev/null 2>&1 || brew install openssl@3
	for f in cmake ninja zstd; do
		command -v "$f" >/dev/null 2>&1 || brew install "$f"
	done
fi

url="https://github.com/libgit2/libgit2/archive/refs/tags/v${version}.tar.gz"
tarball="$work/libgit2-${version}.tar.gz"
fetch "$url" "$tarball" "${LIBGIT2_UPSTREAM_SHA256:-}"
upstream_sha=$(sha256_of "$tarball")
printf '%s\n' "$upstream_sha" >"$out/upstream-sha256.txt"
tar -xzf "$tarball" -C "$work"
src="$work/libgit2-${version}"

# Build libssh2 first, bundled into the prefix; RUNPATH/install-name point at
# /opt/libgit2/lib.
libssh2_url="https://github.com/libssh2/libssh2/archive/refs/tags/libssh2-${libssh2_version}.tar.gz"
fetch "$libssh2_url" "$work/libssh2.tar.gz" "${LIBSSH2_UPSTREAM_SHA256:-}"
libssh2_sha=$(sha256_of "$work/libssh2.tar.gz")
tar -xzf "$work/libssh2.tar.gz" -C "$work"

libssh2_cmake=""
libgit2_cmake=""
case "$os" in
macos)
	libssh2_cmake="-DCMAKE_INSTALL_NAME_DIR=/opt/libgit2/lib -DCMAKE_PREFIX_PATH=$(brew --prefix openssl@3)"
	libgit2_cmake="-DCMAKE_INSTALL_NAME_DIR=/opt/libgit2/lib -DCMAKE_PREFIX_PATH=$prefix;$(brew --prefix openssl@3)"
	;;
linux)
	libgit2_cmake="-DCMAKE_PREFIX_PATH=$prefix -DCMAKE_INSTALL_RPATH=/opt/libgit2/lib"
	;;
esac
# shellcheck disable=SC2086
cmake -S "$work/libssh2-libssh2-${libssh2_version}" -B "$work/libssh2-build" -G Ninja \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$prefix" \
	-DCMAKE_INSTALL_LIBDIR=lib \
	-DBUILD_SHARED_LIBS=ON \
	-DBUILD_EXAMPLES=OFF \
	-DBUILD_TESTING=OFF \
	$libssh2_cmake
cmake --build "$work/libssh2-build" --parallel "$(ncpu)"
cmake --install "$work/libssh2-build"

# shellcheck disable=SC2086
cmake -S "$src" -B "$work/build" -G Ninja \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$prefix" \
	-DCMAKE_INSTALL_LIBDIR=lib \
	-DBUILD_SHARED_LIBS=ON \
	-DBUILD_TESTS=OFF \
	-DUSE_SSH=libssh2 \
	$libgit2_cmake
cmake --build "$work/build" --parallel "$(ncpu)"
cmake --install "$work/build"

# Smoke: link a tiny program against the installed lib and run it.
cat >"$work/smoke.c" <<'EOF'
#include <git2.h>
#include <stdio.h>
int main(void) {
	int major = 0, minor = 0, rev = 0;
	git_libgit2_version(&major, &minor, &rev);
	printf("%d.%d.%d\n", major, minor, rev);
	git_libgit2_shutdown();
	return 0;
}
EOF
${CC:-cc} -O2 -I"$prefix/include" "$work/smoke.c" \
	-L"$prefix/lib" -lgit2 -Wl,-rpath,"$prefix/lib" \
	-o "$work/smoke"
if [ "$os" = macos ]; then
	# Staged dylibs carry /opt/libgit2 install names; repoint the smoke binary
	# at the staging dir.
	dep=$(otool -L "$work/smoke" | awk '/libgit2/ { print $1 }')
	if [ -n "$dep" ]; then
		install_name_tool -change "$dep" "$prefix/lib/$(basename -- "$dep")" "$work/smoke"
		codesign -f -s - "$work/smoke"
	fi
fi
# Staged libs point at /opt/libgit2/lib (absent here); env paths cover the
# transitive libssh2 dep.
smoke_out=$(LD_LIBRARY_PATH="$prefix/lib" DYLD_LIBRARY_PATH="$prefix/lib" "$work/smoke")
echo "smoke: $smoke_out"
case "$smoke_out" in
"$version") ;;
*) echo "libgit2-build.sh: smoke version mismatch: got '$smoke_out', want '$version'" >&2; exit 1 ;;
esac

{
	echo "product=libgit2"
	echo "version=${version}-libssh2-${libssh2_version}"
	echo "platform=$platform"
	echo "upstream-url=$url"
	echo "upstream-sha256=$upstream_sha"
	echo "libssh2-url=$libssh2_url"
	echo "libssh2-sha256=$libssh2_sha"
	if [ "$os" = linux ]; then
		echo "flags=Release BUILD_SHARED_LIBS=ON BUILD_TESTS=OFF USE_SSH=libssh2 (bundled ${libssh2_version}) USE_HTTPS=OpenSSL (system)"
	else
		echo "flags=Release BUILD_SHARED_LIBS=ON BUILD_TESTS=OFF USE_SSH=libssh2 (bundled ${libssh2_version}) USE_HTTPS=OpenSSL (brew)"
	fi
	echo "cc=$(${CC:-cc} --version | head -n 1)"
	echo "cmake=$(cmake --version | head -n 1)"
	true
} >"$prefix/BUILD-INFO.txt"

asset="$out/libgit2-${version}-libssh2-${libssh2_version}-${platform}.tar.zst"
sh "$script_dir/pack.sh" "$work/stage" "$asset" opt

# Re-extract the archive and re-check layout, links, and (macOS) signatures.
verify="$work/verify"
verify_extract "$asset" "$verify"
[ -f "$verify/opt/libgit2/BUILD-INFO.txt" ] && [ -f "$verify/opt/libgit2/include/git2.h" ] || {
	echo "libgit2-build.sh: packaged archive layout unexpected" >&2
	exit 1
}
if [ "$os" = macos ]; then
	for lib in "$verify"/opt/libgit2/lib/*.dylib; do
		codesign --verify "$lib"
	done
else
	[ -e "$verify/opt/libgit2/lib/libgit2.so" ] || {
		echo "libgit2-build.sh: packaged archive is missing libgit2.so" >&2
		exit 1
	}
	ls "$verify"/opt/libgit2/lib/libssh2.so* >/dev/null 2>&1 || {
		echo "libgit2-build.sh: packaged archive is missing bundled libssh2" >&2
		exit 1
	}
fi
echo "built $asset"
