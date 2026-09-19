#!/bin/sh
# Build aws-lc shared libs, smoke-test, and pack a tar.zst rooted at opt/aws-lc
# (extract at / to install).
# usage: aws-lc-build.sh <version>
# env:
#   AWS_LC_PLATFORM        asset platform suffix, e.g. linux-x64 (required)
#   AWS_LC_WORK            work dir (default .aws-lc-work)
#   AWS_LC_UPSTREAM_SHA256 optional expected sha256 of the upstream source tarball
set -eu
version="${1:?usage: aws-lc-build.sh <version>}"
platform="${AWS_LC_PLATFORM:?AWS_LC_PLATFORM must be set (e.g. linux-x64)}"
work="${AWS_LC_WORK:-$PWD/.aws-lc-work}"
out="$work/out"
prefix="$work/stage/opt/aws-lc"

case "$(uname -s)" in
Darwin) os=macos ;;
Linux) os=linux ;;
*) echo "aws-lc-build.sh: unsupported host $(uname -s)" >&2; exit 1 ;;
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
		build-essential cmake ninja-build lld perl zstd
	setup_linux_toolchain
else
	for f in cmake ninja go perl zstd; do
		command -v "$f" >/dev/null 2>&1 || brew install "$f"
	done
fi
command -v go >/dev/null 2>&1 || {
	echo "aws-lc-build.sh: go is required to build aws-lc (CI uses actions/setup-go)" >&2
	exit 1
}

url="https://github.com/aws/aws-lc/archive/refs/tags/v${version}.tar.gz"
tarball="$work/aws-lc-v${version}.tar.gz"
fetch "$url" "$tarball" "${AWS_LC_UPSTREAM_SHA256:-}"
upstream_sha=$(sha256_of "$tarball")
printf '%s\n' "$upstream_sha" >"$out/upstream-sha256.txt"
tar -xzf "$tarball" -C "$work"
src="$work/aws-lc-${version}"

# Release build, shared libs; pin macOS dylib install names to /opt/aws-lc/lib.
case "$os" in
macos)
	extra_cmake="-DCMAKE_INSTALL_NAME_DIR=/opt/aws-lc/lib"
	smoke_ldflags="-Wl,-headerpad_max_install_names"
	;;
*)
	extra_cmake=""
	smoke_ldflags=""
	;;
esac
# shellcheck disable=SC2086
cmake -S "$src" -B "$work/build" -G Ninja \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$prefix" \
	-DCMAKE_INSTALL_LIBDIR=lib \
	-DBUILD_SHARED_LIBS=1 \
	-DBUILD_LIBSSL=ON \
	-DBUILD_TESTING=OFF \
	-DDISABLE_CPU_JITTER_ENTROPY=ON \
	$extra_cmake
cmake --build "$work/build" --parallel "$(ncpu)"
cmake --install "$work/build"

# Smoke: link a tiny program against the installed libs and run it.
cat >"$work/smoke.c" <<'EOF'
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <stdio.h>
#include <string.h>
int main(void) {
	static const char msg[] = "ci-releases";
	unsigned char md[EVP_MAX_MD_SIZE];
	unsigned int len = 0;
	EVP_MD_CTX *ctx = EVP_MD_CTX_new();
	if (!ctx) return 2;
	int ok = EVP_DigestInit_ex(ctx, EVP_sha256(), NULL) == 1 &&
	         EVP_DigestUpdate(ctx, msg, sizeof(msg) - 1) == 1 &&
	         EVP_DigestFinal_ex(ctx, md, &len) == 1;
	EVP_MD_CTX_free(ctx);
	if (!ok || len != 32) return 3;
	printf("%s\n", OpenSSL_version(0));
	return 0;
}
EOF
# shellcheck disable=SC2086
${CC:-cc} -O2 -I"$prefix/include" "$work/smoke.c" $smoke_ldflags \
	-L"$prefix/lib" -lssl -lcrypto -Wl,-rpath,"$prefix/lib" \
	-o "$work/smoke"
if [ "$os" = macos ]; then
	# Staged dylibs carry /opt/aws-lc install names; repoint the smoke binary
	# at the staging dir.
	install_name_tool \
		-change /opt/aws-lc/lib/libssl.dylib "$prefix/lib/libssl.dylib" \
		-change /opt/aws-lc/lib/libcrypto.dylib "$prefix/lib/libcrypto.dylib" \
		"$work/smoke"
	codesign -f -s - "$work/smoke"
fi
smoke_out=$("$work/smoke")
echo "smoke: $smoke_out"
echo "$smoke_out" | grep -qi aws-lc || {
	echo "aws-lc-build.sh: smoke binary is not linked against aws-lc" >&2
	exit 1
}

if [ "$os" = macos ]; then
	for lib in "$prefix/lib"/libcrypto*.dylib "$prefix/lib"/libssl*.dylib; do
		[ -f "$lib" ] || continue
		id=$(otool -D "$lib" | sed -n 2p)
		case "$id" in
		/opt/aws-lc/lib/*) ;;
		*) echo "aws-lc-build.sh: unexpected install name for $lib: $id" >&2; exit 1 ;;
		esac
	done
	otool -L "$prefix/lib"/libssl*.dylib | grep -q '/opt/aws-lc/lib/libcrypto' || {
		echo "aws-lc-build.sh: libssl does not reference libcrypto via /opt/aws-lc" >&2
		exit 1
	}
fi

{
	echo "product=aws-lc"
	echo "version=$version"
	echo "platform=$platform"
	echo "upstream-url=$url"
	echo "upstream-sha256=$upstream_sha"
	echo "flags=Release BUILD_SHARED_LIBS=1 BUILD_LIBSSL=ON BUILD_TESTING=OFF DISABLE_CPU_JITTER_ENTROPY=ON"
	echo "cc=$(${CC:-cc} --version | head -n 1)"
	echo "cmake=$(cmake --version | head -n 1)"
	command -v go >/dev/null 2>&1 && echo "go=$(go version)"
	true
} >"$prefix/BUILD-INFO.txt"

asset="$out/aws-lc-${version}-${platform}.tar.zst"
sh "$script_dir/pack.sh" "$work/stage" "$asset" opt

# Re-extract the archive and re-check layout, links, and (macOS) signatures.
verify="$work/verify"
verify_extract "$asset" "$verify"
[ -f "$verify/opt/aws-lc/BUILD-INFO.txt" ] || {
	echo "aws-lc-build.sh: packaged archive is missing BUILD-INFO.txt" >&2
	exit 1
}
case "$os" in
macos)
	for lib in "$verify"/opt/aws-lc/lib/*.dylib; do
		codesign --verify "$lib"
	done
	otool -L "$verify"/opt/aws-lc/lib/libssl*.dylib | grep -q '/opt/aws-lc/lib/libcrypto' || {
		echo "aws-lc-build.sh: extracted libssl lost its libcrypto reference" >&2
		exit 1
	}
	;;
linux)
	[ -e "$verify/opt/aws-lc/lib/libcrypto.so" ] && [ -e "$verify/opt/aws-lc/lib/libssl.so" ] || {
		echo "aws-lc-build.sh: packaged archive is missing shared libraries" >&2
		exit 1
	}
	;;
esac
echo "built $asset"
