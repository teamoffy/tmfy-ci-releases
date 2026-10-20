#!/bin/sh
set -eu
version="${1:?usage: sqlite-build.sh <version>}"
platform="${SQLITE_PLATFORM:?SQLITE_PLATFORM must be set}"
encoded=$(printf '%s\n' "$version" | awk -F. '
	NR == 1 && NF == 3 && $1 ~ /^3$/ && $2 ~ /^(0|[1-9][0-9]?)$/ && $3 ~ /^(0|[1-9][0-9]?)$/ {
		printf "%d%02d%02d00", $1, $2, $3; valid = 1
	}
	END { if (NR != 1 || !valid) exit 1 }
') || {
	echo "sqlite-build.sh: invalid SQLite version '$version' (expected 3.MINOR.PATCH)" >&2
	exit 1
}
work="${SQLITE_WORK:-$PWD/.sqlite-work}"
out="$work/out"
prefix="$work/stage/opt/sqlite"

case "$(uname -s)-$(uname -m)-$platform" in
Linux-x86_64-linux-x64 | Linux-aarch64-linux-arm64) os=linux ;;
Darwin-arm64-darwin-arm64) os=macos ;;
*) echo "sqlite-build.sh: platform does not match the supported native host: $platform" >&2; exit 1 ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib.sh
. "$script_dir/lib.sh"
setup_cpu_baseline "$platform"
rm -rf "$work"
mkdir -p "$prefix" "$out"

if [ "$os" = linux ]; then
	sudo apt-get update
	sudo apt-get install -y --no-install-recommends build-essential lld python3 zstd
	setup_linux_toolchain
	LDFLAGS="$LDFLAGS -Wl,-rpath,/opt/sqlite/lib"
	export LDFLAGS
else
	ensure_cmds make python3 zstd
fi

release_log="https://www.sqlite.org/releaselog/$(printf '%s' "$version" | tr . _).html"
fetch "$release_log" "$work/release.html"
year=$(sed -n 's/.*SQLite Release [^ ]* On \([0-9][0-9][0-9][0-9]\)-.*/\1/p' "$work/release.html" | sort -u)
core_sha3=$(sed -n 's/.*SHA3-256 for sqlite3.c: *\([0-9a-f]\{64\}\).*/\1/p' "$work/release.html")
[ -n "$year" ] && [ -n "$core_sha3" ] || {
	echo "sqlite-build.sh: release date or sqlite3.c SHA3-256 missing from $release_log" >&2
	exit 1
}
url="https://www.sqlite.org/$year/sqlite-autoconf-$encoded.tar.gz"
tarball="$work/sqlite-$version.tar.gz"
fetch "$url" "$tarball" "${SQLITE_UPSTREAM_SHA256:-}"
upstream_sha=$(sha256_of "$tarball")
printf '%s\n' "$upstream_sha" >"$out/upstream-sha256.txt"
tar -xzf "$tarball" -C "$work"
src="$work/sqlite-autoconf-$encoded"
actual_sha3=$(python3 -c 'import hashlib, pathlib, sys; print(hashlib.sha3_256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "$src/sqlite3.c")
[ "$actual_sha3" = "$core_sha3" ] || {
	echo "sqlite-build.sh: sqlite3.c SHA3-256 mismatch: expected $core_sha3, got $actual_sha3" >&2
	exit 1
}

(
	cd "$src"
	set -- --prefix=/opt/sqlite --disable-readline --disable-static-shell \
		--fts5 --rtree --dbstat --column-metadata --scanstatus
	if [ "$os" = linux ]; then
		set -- "$@" --soname=legacy
	fi
	./configure "$@"
	make -j"$(ncpu)"
	make DESTDIR="$work/stage" install
)

cat >"$work/smoke.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include <sqlite3.h>
int main(void) {
	sqlite3 *database = NULL;
	sqlite3_stmt *statement = NULL;
	if (strcmp(sqlite3_libversion(), SQLITE_VERSION) != 0 || sqlite3_threadsafe() == 0) return 1;
	if (!sqlite3_compileoption_used("ENABLE_FTS5") ||
	    !sqlite3_compileoption_used("ENABLE_RTREE") ||
	    !sqlite3_compileoption_used("ENABLE_DBSTAT_VTAB") ||
	    !sqlite3_compileoption_used("ENABLE_COLUMN_METADATA") ||
	    !sqlite3_compileoption_used("ENABLE_STMT_SCANSTATUS") ||
	    sqlite3_compileoption_used("OMIT_LOAD_EXTENSION")) return 2;
	if (sqlite3_open(":memory:", &database) != SQLITE_OK) return 3;
	if (sqlite3_exec(database, "CREATE TABLE records(value); INSERT INTO records VALUES(42)", NULL, NULL, NULL) != SQLITE_OK) return 4;
	if (sqlite3_prepare_v2(database, "SELECT value FROM records", -1, &statement, NULL) != SQLITE_OK) return 5;
	if (sqlite3_step(statement) != SQLITE_ROW || sqlite3_column_int(statement, 0) != 42) return 6;
	sqlite3_finalize(statement);
	if (sqlite3_close(database) != SQLITE_OK) return 7;
	puts(sqlite3_libversion());
	return 0;
}
EOF

smoke() {
	root=$1
	case "$os" in
	macos) library="$root/lib/libsqlite3.dylib" ;;
	linux) library="$root/lib/libsqlite3.so" ;;
	esac
	[ -f "$library" ]
	[ -s "$root/lib/libsqlite3.a" ]
	[ -s "$root/include/sqlite3.h" ] && [ -s "$root/include/sqlite3ext.h" ]
	${CC:-cc} -O2 -I"$root/include" "$work/smoke.c" \
		-L"$root/lib" -lsqlite3 -Wl,-rpath,"$root/lib" -o "$work/smoke"
	library_version=$(LD_LIBRARY_PATH="$root/lib" DYLD_LIBRARY_PATH="$root/lib" "$work/smoke")
	cli_version=$(LD_LIBRARY_PATH="$root/lib" DYLD_LIBRARY_PATH="$root/lib" "$root/bin/sqlite3" :memory: 'SELECT sqlite_version()')
	echo "smoke: library=$library_version CLI=$cli_version"
	[ "$library_version" = "$version" ] && [ "$cli_version" = "$version" ] || {
		echo "sqlite-build.sh: expected SQLite $version from $root" >&2
		exit 1
	}
}
smoke "$prefix"

{
	echo "product=sqlite"
	echo "version=$version"
	echo "platform=$platform"
	echo "cpu-baseline=$CPU_BASELINE"
	echo "cflags=$CFLAGS"
	echo "cxxflags=$CXXFLAGS"
	echo "upstream-url=$url"
	echo "upstream-sha256=$upstream_sha"
	echo "sqlite3.c-sha3-256=$core_sha3"
	echo "flags=shared static dynamic-shell fts5 rtree dbstat column-metadata scanstatus threadsafe load-extension"
	${CC:-cc} --version
} >"$prefix/BUILD-INFO.txt"

asset="$out/sqlite-$version-$platform.tar.zst"
sh "$script_dir/pack.sh" "$work/stage" "$asset" opt
verify_extract "$asset" "$work/verify"
smoke "$work/verify/opt/sqlite"
if [ "$os" = macos ]; then
	for library in "$work/verify/opt/sqlite/lib/"*.dylib; do
		codesign --verify "$library"
	done
fi
echo "built $asset"
