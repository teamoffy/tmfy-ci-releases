#!/bin/sh
# Pack the official prebuilt valkey server + a from-source valkey-bloom module
# into opt/valkey. Linux only (server tarballs and the .so module are linux).
# usage: valkey-build.sh <valkey-version> <bloom-version>
# env:
#   VALKEY_PLATFORM          asset platform suffix, e.g. linux-x64 (required)
#   VALKEY_WORK              work dir (default .valkey-work)
#   VALKEY_UPSTREAM_SHA256   optional expected sha256 of the valkey tarball
#   BLOOM_UPSTREAM_SHA256    optional expected sha256 of the bloom source tarball
set -eu
valkey_version="${1:?usage: valkey-build.sh <valkey-version> <bloom-version>}"
bloom_version="${2:?usage: valkey-build.sh <valkey-version> <bloom-version>}"
platform="${VALKEY_PLATFORM:?VALKEY_PLATFORM must be set (e.g. linux-x64)}"
work="${VALKEY_WORK:-$PWD/.valkey-work}"
out="$work/out"
prefix="$work/stage/opt/valkey"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"
require_linux valkey-build.sh "unpacks Linux server binaries and needs cargo for the bloom module"

# Native build: the host arch has to match the server tarball we unpack.
case "$(uname -m)" in
x86_64) arch=x86_64 ;;
aarch64) arch=arm64 ;;
*) echo "valkey-build.sh: unsupported arch $(uname -m) (x86_64|aarch64)" >&2; exit 1 ;;
esac

rm -rf "$work"
mkdir -p "$prefix/modules" "$out"
UPSTREAM_SHA_LOG="$work/upstream-sha256s.txt"
: >"$UPSTREAM_SHA_LOG"

# cargo builds the bloom module; build-essential gives rustc a C linker.
sudo apt-get update
sudo apt-get install -y --no-install-recommends build-essential cargo zstd

# Official server binaries — the "noble" builds on download.valkey.io.
valkey_url="https://download.valkey.io/releases/valkey-${valkey_version}-noble-${arch}.tar.gz"
fetch "$valkey_url" "$work/valkey.tar.gz" "${VALKEY_UPSTREAM_SHA256:-}"
tar -xzf "$work/valkey.tar.gz" -C "$prefix" --strip-components=1
[ -x "$prefix/bin/valkey-server" ] || {
	echo "valkey-build.sh: valkey tarball layout unexpected: no bin/valkey-server" >&2
	exit 1
}

# Build valkey-bloom from source and bundle it with the server.
bloom_url="https://github.com/valkey-io/valkey-bloom/archive/refs/tags/${bloom_version}.tar.gz"
fetch "$bloom_url" "$work/bloom.tar.gz" "${BLOOM_UPSTREAM_SHA256:-}"
tar -xzf "$work/bloom.tar.gz" -C "$work"
cargo build --release --manifest-path "$work/valkey-bloom-${bloom_version}/Cargo.toml"
cp "$work/valkey-bloom-${bloom_version}/target/release/libvalkey_bloom.so" "$prefix/modules/"

# Smoke: boot the server with the module loaded.
port=56379
stop_server() { "$prefix/bin/valkey-cli" -p "$port" shutdown nosave >/dev/null 2>&1 || true; }
"$prefix/bin/valkey-server" --bind 127.0.0.1 --port "$port" --save '' --appendonly no \
	--protected-mode no --loadmodule "$prefix/modules/libvalkey_bloom.so" \
	--daemonize yes --logfile "$work/valkey.log"
trap stop_server EXIT INT TERM
for _ in $(seq 1 30); do
	"$prefix/bin/valkey-cli" -p "$port" ping >/dev/null 2>&1 && break
	sleep 1
done
"$prefix/bin/valkey-cli" -p "$port" ping
"$prefix/bin/valkey-cli" -p "$port" MODULE LIST | grep -qi bloom || {
	echo "valkey-build.sh: bloom module did not register" >&2
	exit 1
}
stop_server
trap - EXIT INT TERM

{
	echo "product=valkey"
	echo "version=${valkey_version}-bloom${bloom_version}"
	echo "platform=$platform"
	echo "server-source=$valkey_url (official noble build)"
	echo "bloom-build=cargo release"
	echo "upstream-checksums:"
	cat "$UPSTREAM_SHA_LOG"
	true
} >"$prefix/BUILD-INFO.txt"

asset="$out/valkey-${valkey_version}-bloom${bloom_version}-${platform}.tar.zst"
sh "$script_dir/pack.sh" "$work/stage" "$asset" opt

# Re-extract the archive and re-check the layout.
verify="$work/verify"
verify_extract "$asset" "$verify"
[ -x "$verify/opt/valkey/bin/valkey-server" ] && [ -f "$verify/opt/valkey/modules/libvalkey_bloom.so" ] && [ -f "$verify/opt/valkey/BUILD-INFO.txt" ] || {
	echo "valkey-build.sh: packaged archive layout unexpected" >&2
	exit 1
}
echo "built $asset"
