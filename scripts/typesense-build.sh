#!/bin/sh
# Pack the official prebuilt typesense-server into opt/typesense.
# Linux only: upstream publishes no macOS server build.
# usage: typesense-build.sh <version>
# env:
#   TYPESENSE_PLATFORM        asset platform suffix, e.g. linux-x64 (required)
#   TYPESENSE_WORK            work dir (default .typesense-work)
#   TYPESENSE_UPSTREAM_SHA256 optional expected sha256 of the upstream tarball
set -eu
version="${1:?usage: typesense-build.sh <version>}"
platform="${TYPESENSE_PLATFORM:?TYPESENSE_PLATFORM must be set (e.g. linux-x64)}"
work="${TYPESENSE_WORK:-$PWD/.typesense-work}"
out="$work/out"
prefix="$work/stage/opt/typesense"

case "$platform" in
linux-x64) arch=amd64 ;;
linux-arm64) arch=arm64 ;;
*) echo "typesense-build.sh: unsupported platform '$platform' (linux-x64|linux-arm64)" >&2; exit 1 ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"
require_linux typesense-build.sh "upstream ships Linux server binaries only"
rm -rf "$work"
mkdir -p "$prefix" "$out"

ensure_cmds zstd # for pack.sh; preinstalled on the runner images

url="https://dl.typesense.org/releases/${version}/typesense-server-${version}-linux-${arch}.tar.gz"
tarball="$work/typesense-server.tar.gz"
fetch "$url" "$tarball" "${TYPESENSE_UPSTREAM_SHA256:-}"
sha256_of "$tarball" >"$out/upstream-sha256.txt"
tar -xzf "$tarball" -C "$prefix"
[ -x "$prefix/typesense-server" ] || {
	echo "typesense-build.sh: tarball layout unexpected: no typesense-server at root" >&2
	exit 1
}

# Smoke: boot the server on /dev/shm and hit /health.
data=/dev/shm/typesense-smoke
rm -rf "$data"
mkdir -p "$data"
"$prefix/typesense-server" --data-dir="$data" --api-key=xyz-typesense-test-key \
	--api-address=127.0.0.1 --api-port=8108 >"$work/typesense.log" 2>&1 &
server_pid=$!
cleanup() {
	kill "$server_pid" 2>/dev/null || true
	rm -rf "$data"
}
trap cleanup EXIT INT TERM
for _ in $(seq 1 30); do
	curl -fsS http://127.0.0.1:8108/health >/dev/null 2>&1 && break
	sleep 1
done
curl -fsS http://127.0.0.1:8108/health >/dev/null
# Pack a quiesced tree: nothing should be writing under $prefix.
cleanup
trap - EXIT INT TERM

{
	echo "product=typesense"
	echo "version=$version"
	echo "platform=$platform"
	echo "source=$url"
	echo "upstream-sha256=$(head -n 1 "$out/upstream-sha256.txt")"
	true
} >"$prefix/BUILD-INFO.txt"

asset="$out/typesense-${version}-${platform}.tar.zst"
sh "$script_dir/pack.sh" "$work/stage" "$asset" opt

# Re-extract the archive and re-check the layout.
verify="$work/verify"
verify_extract "$asset" "$verify"
[ -x "$verify/opt/typesense/typesense-server" ] && [ -f "$verify/opt/typesense/BUILD-INFO.txt" ] || {
	echo "typesense-build.sh: packaged archive layout unexpected" >&2
	exit 1
}
echo "built $asset"
