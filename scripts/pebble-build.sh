#!/bin/sh
# Pack the official prebuilt pebble binaries + test config/certs into
# opt/pebble. Linux only: we consume upstream's Linux release binaries.
# usage: pebble-build.sh <version>
# env:
#   PEBBLE_PLATFORM        asset platform suffix, e.g. linux-x64 (required)
#   PEBBLE_WORK            work dir (default .pebble-work)
#   PEBBLE_BIN_UPSTREAM_SHA256     optional expected sha256 of the pebble binary tarball
#   PEBBLE_SRC_UPSTREAM_SHA256     optional expected sha256 of the source tarball
set -eu
version="${1:?usage: pebble-build.sh <version>}"
platform="${PEBBLE_PLATFORM:?PEBBLE_PLATFORM must be set (e.g. linux-x64)}"
work="${PEBBLE_WORK:-$PWD/.pebble-work}"
out="$work/out"
prefix="$work/stage/opt/pebble"

case "$platform" in
linux-x64) arch=amd64 ;;
linux-arm64) arch=arm64 ;;
*) echo "pebble-build.sh: unsupported platform '$platform' (linux-x64|linux-arm64)" >&2; exit 1 ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"
require_linux pebble-build.sh "upstream ships Linux binaries only"
rm -rf "$work"
mkdir -p "$prefix/bin" "$prefix/test" "$out"
UPSTREAM_SHA_LOG="$work/upstream-sha256s.txt"
: >"$UPSTREAM_SHA_LOG"

ensure_cmds zstd # for pack.sh; preinstalled on the runner images

base="https://github.com/letsencrypt/pebble/releases/download/v${version}"

fetch "$base/pebble-linux-${arch}.tar.gz" "$work/pebble.tar.gz" "${PEBBLE_BIN_UPSTREAM_SHA256:-}"
tar -xzf "$work/pebble.tar.gz" -C "$prefix/bin" --strip-components=3
fetch "$base/pebble-challtestsrv-linux-${arch}.tar.gz" "$work/challtestsrv.tar.gz"
tar -xzf "$work/challtestsrv.tar.gz" -C "$prefix/bin" --strip-components=3
fetch "https://github.com/letsencrypt/pebble/archive/refs/tags/v${version}.tar.gz" "$work/source.tar.gz" "${PEBBLE_SRC_UPSTREAM_SHA256:-}"
tar -xzf "$work/source.tar.gz" -C "$prefix/test" --strip-components=2 \
	"pebble-${version}/test/config" "pebble-${version}/test/certs"
chmod +x "$prefix/bin/pebble" "$prefix/bin/pebble-challtestsrv"

[ -x "$prefix/bin/pebble" ] && [ -x "$prefix/bin/pebble-challtestsrv" ] && [ -f "$prefix/test/config/pebble-config.json" ] || {
	echo "pebble-build.sh: tarball layout unexpected" >&2
	exit 1
}

# Smoke: boot pebble + challtestsrv and hit the ACME directory.
"$prefix/bin/pebble-challtestsrv" -defaultIPv4 127.0.0.1 \
	>"$work/challtestsrv.log" 2>&1 &
challtestsrv_pid=$!
(
	cd "$prefix"
	export PEBBLE_VA_NOSLEEP=1 PEBBLE_WFE_NONCEREJECT=0
	exec "$prefix/bin/pebble" -config "$prefix/test/config/pebble-config.json" \
		-strict=false -dnsserver 127.0.0.1:8053
) >"$work/pebble.log" 2>&1 &
pebble_pid=$!
cleanup() {
	kill "$pebble_pid" "$challtestsrv_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
for _ in $(seq 1 30); do
	curl -ksf https://127.0.0.1:14000/dir >/dev/null && break
	sleep 1
done
curl -ksf https://127.0.0.1:14000/dir >/dev/null || {
	cat "$work/pebble.log" >&2
	exit 1
}
# Pack a quiesced tree: nothing should be writing under $prefix.
cleanup
trap - EXIT INT TERM

{
	echo "product=pebble"
	echo "version=$version"
	echo "platform=$platform"
	echo "source-base=$base"
	echo "upstream-checksums:"
	cat "$UPSTREAM_SHA_LOG"
	true
} >"$prefix/BUILD-INFO.txt"

asset="$out/pebble-${version}-${platform}.tar.zst"
sh "$script_dir/pack.sh" "$work/stage" "$asset" opt

# Re-extract the archive and re-check the layout.
verify="$work/verify"
verify_extract "$asset" "$verify"
[ -x "$verify/opt/pebble/bin/pebble" ] && [ -f "$verify/opt/pebble/test/config/pebble-config.json" ] && [ -f "$verify/opt/pebble/BUILD-INFO.txt" ] || {
	echo "pebble-build.sh: packaged archive layout unexpected" >&2
	exit 1
}
echo "built $asset"
