#!/bin/sh
# Pack the official prebuilt ClickHouse tarballs into opt/clickhouse.
# Linux only: upstream publishes no macOS server tarball.
# usage: clickhouse-build.sh <version>
# env:
#   CLICKHOUSE_PLATFORM              asset platform suffix, e.g. linux-x64 (required)
#   CLICKHOUSE_WORK                  work dir (default .clickhouse-work)
#   CLICKHOUSE_COMMON_UPSTREAM_SHA256  optional expected sha256 of the common-static tarball
#   CLICKHOUSE_SERVER_UPSTREAM_SHA256  optional expected sha256 of the server tarball
set -eu
version="${1:?usage: clickhouse-build.sh <version>}"
platform="${CLICKHOUSE_PLATFORM:?CLICKHOUSE_PLATFORM must be set (e.g. linux-x64)}"
work="${CLICKHOUSE_WORK:-$PWD/.clickhouse-work}"
out="$work/out"
prefix="$work/stage/opt/clickhouse"

case "$platform" in
linux-x64) arch=amd64 ;;
linux-arm64) arch=arm64 ;;
*) echo "clickhouse-build.sh: unsupported platform '$platform' (linux-x64|linux-arm64)" >&2; exit 1 ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"
require_linux clickhouse-build.sh "upstream ships Linux server tarballs only"
rm -rf "$work"
mkdir -p "$prefix" "$out"
UPSTREAM_SHA_LOG="$work/upstream-sha256s.txt"
: >"$UPSTREAM_SHA_LOG"

ensure_cmds zstd # for pack.sh; preinstalled on the runner images

base="https://github.com/ClickHouse/ClickHouse/releases/download/v${version}-lts"

fetch "$base/clickhouse-common-static-${version}-${arch}.tgz" \
	"$work/common-static.tar.gz" "${CLICKHOUSE_COMMON_UPSTREAM_SHA256:-}"
tar -xzf "$work/common-static.tar.gz" -C "$prefix" --strip-components=1
fetch "$base/clickhouse-server-${version}-${arch}.tgz" \
	"$work/server.tar.gz" "${CLICKHOUSE_SERVER_UPSTREAM_SHA256:-}"
tar -xzf "$work/server.tar.gz" -C "$prefix" --strip-components=1

[ -e "$prefix/usr/bin/clickhouse" ] && [ -f "$prefix/etc/clickhouse-server/config.xml" ] || {
	echo "clickhouse-build.sh: tarball layout unexpected (missing usr/bin/clickhouse or server config)" >&2
	exit 1
}

# Smoke: the multi-call binary reports the version.
version_out=$("$prefix/usr/bin/clickhouse" --version 2>/dev/null | head -n 1) || {
	echo "clickhouse-build.sh: clickhouse binary does not run" >&2
	exit 1
}
echo "smoke: $version_out"
case "$version_out" in
*"$version"*) ;;
*) echo "clickhouse-build.sh: version mismatch: got '$version_out', want '*$version*'" >&2; exit 1 ;;
esac

{
	echo "product=clickhouse"
	echo "version=$version"
	echo "platform=$platform"
	echo "source-base=$base"
	echo "upstream-checksums:"
	cat "$UPSTREAM_SHA_LOG"
	true
} >"$prefix/BUILD-INFO.txt"

asset="$out/clickhouse-${version}-${platform}.tar.zst"
sh "$script_dir/pack.sh" "$work/stage" "$asset" opt

# Re-extract the archive and re-check the layout.
verify="$work/verify"
verify_extract "$asset" "$verify"
[ -e "$verify/opt/clickhouse/usr/bin/clickhouse" ] && [ -f "$verify/opt/clickhouse/BUILD-INFO.txt" ] || {
	echo "clickhouse-build.sh: packaged archive layout unexpected" >&2
	exit 1
}
echo "built $asset"
