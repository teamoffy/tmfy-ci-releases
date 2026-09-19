#!/bin/sh
# Mirror the official sqlite-vec loadable extension as tar.zst assets rooted
# at opt/sqlite-vec (extract at / to install into /opt/sqlite-vec).
# usage: sqlite-vec-repack.sh <version>
# env:
#   SQLITE_VEC_WORK       work dir (default .sqlite-vec-work)
#   SQLITE_VEC_PLATFORMS  space-separated subset to build (default: all three)
set -eu
version="${1:?usage: sqlite-vec-repack.sh <version>}"
work="${SQLITE_VEC_WORK:-$PWD/.sqlite-vec-work}"
out="$work/out"
platforms="${SQLITE_VEC_PLATFORMS:-linux-x64 linux-arm64 darwin-arm64}"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"
rm -rf "$work"
mkdir -p "$out" "$work/dl"

ensure_cmds zstd python3 # preinstalled on the runner images

base="https://github.com/asg017/sqlite-vec/releases/download/v${version}"

# Upstream checksums.txt is "<asset> <sha256>" per line — name first, the
# reverse of the sha256sum format.
checksums="$work/checksums.txt"
fetch "$base/checksums.txt" "$checksums"

# Smoke loads vec0 and checks vec_version(); only meaningful when the host can
# execute the platform's binary.
cat >"$work/smoke.py" <<'PYEOF'
import os
import sqlite3
import sys

con = sqlite3.connect(":memory:")
con.enable_load_extension(True)
con.load_extension(os.environ["VEC0"])
got = con.execute("select vec_version()").fetchone()[0]
print(f"smoke: vec_version()={got}")
sys.exit(0 if got == os.environ["VEC0_VERSION"] else 3)
PYEOF

host="$(uname -s)-$(uname -m)"
for platform in $platforms; do
	case "$platform" in
	linux-x64) target=linux-x86_64; ext=so ;;
	linux-arm64) target=linux-aarch64; ext=so ;;
	darwin-arm64) target=macos-aarch64; ext=dylib ;;
	*)
		echo "sqlite-vec-repack.sh: unsupported platform '$platform'" >&2
		exit 1
		;;
	esac
	name="sqlite-vec-${version}-loadable-${target}.tar.gz"
	tgz="$work/dl/$name"
	fetch "$base/$name" "$tgz"

	expected=$(awk -v n="$name" '$1 == n { print $2 }' "$checksums")
	actual=$(sha256_of "$tgz")
	if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
		echo "sqlite-vec-repack.sh: checksum mismatch for $name: expected ${expected:-<missing>}, got $actual" >&2
		exit 1
	fi

	rm -rf "$work/dl/vec0."* "$work/stage"
	tar -xzf "$tgz" -C "$work/dl"
	[ -f "$work/dl/vec0.$ext" ] || {
		echo "sqlite-vec-repack.sh: $name does not contain vec0.$ext" >&2
		exit 1
	}
	prefix="$work/stage/opt/sqlite-vec"
	mkdir -p "$prefix/lib"
	mv "$work/dl/vec0.$ext" "$prefix/lib/"

	{
		echo "product=sqlite-vec"
		echo "version=$version"
		echo "platform=$platform"
		echo "upstream-url=$base/$name"
		echo "upstream-sha256=$actual"
		echo "recipe=repack of the upstream loadable vec0 extension (checksums.txt verified)"
		true
	} >"$prefix/BUILD-INFO.txt"

	asset="$out/sqlite-vec-${version}-${platform}.tar.zst"
	sh "$script_dir/pack.sh" "$work/stage" "$asset" opt

	# Re-extract and confirm the repack preserved the payload, then load the
	# extension natively when the host matches the target.
	verify="$work/verify"
	verify_extract "$asset" "$verify"
	vec0="$verify/opt/sqlite-vec/lib/vec0.$ext"
	[ -s "$vec0" ] || {
		echo "sqlite-vec-repack.sh: packaged archive is missing opt/sqlite-vec/lib/vec0.$ext" >&2
		exit 1
	}
	case "$platform-$host" in
	linux-x64-Linux-x86_64 | linux-arm64-Linux-aarch64 | darwin-arm64-Darwin-arm64)
		VEC0="$vec0" VEC0_VERSION="v$version" python3 "$work/smoke.py" || {
			echo "sqlite-vec-repack.sh: vec_version() mismatch for $platform" >&2
			exit 1
		}
		;;
	*) echo "smoke: skipped load test (host $host cannot run $platform)" ;;
	esac
	echo "mirrored $asset"
done
