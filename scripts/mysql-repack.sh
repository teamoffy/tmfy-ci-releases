#!/bin/sh
# Repack the official MySQL "Linux - Generic" binary tarball into a tar.zst
# rooted at opt/mysql: bin/{mysqld,mysql,mysqladmin}, lib/{plugin,private,
# mecab,libmysqlclient.so*}, share/, LICENSE. The binaries' RUNPATH already
# covers $ORIGIN/../lib/private, so the runtime deps the ubuntu images lack
# (libaio, libnuma, ncurses/tinfo) are bundled there — verified by ldd
# resolving every non-core soname into the staging dir, then a live
# --initialize-insecure + server boot smoke test. Linux only.
# usage: mysql-repack.sh <version>   e.g. mysql-repack.sh 9.7.2
# env:
#   MYSQL_PLATFORM  asset platform suffix, e.g. linux-arm64 (required)
#   MYSQL_WORK      work dir (default .mysql-work)
#   Optional expected sha256 check (skipped when unset): MYSQL_UPSTREAM_SHA256
set -eu
version="${1:?usage: mysql-repack.sh <version>}"
platform="${MYSQL_PLATFORM:?MYSQL_PLATFORM must be set (e.g. linux-arm64)}"
work="${MYSQL_WORK:-$PWD/.mysql-work}"
out="$work/out"
prefix="$work/stage/opt/mysql"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"
require_linux mysql-repack.sh "the generic tarballs and the asset both target Linux runners"

case "$platform" in
linux-arm64) mysql_arch=aarch64 ;;
linux-x64) mysql_arch=x86_64 ;;
*) echo "mysql-repack.sh: unsupported platform '$platform'" >&2; exit 1 ;;
esac

rm -rf "$work"
mkdir -p "$prefix/bin" "$prefix/lib" "$prefix/share" "$out" "$work/src"

UPSTREAM_SHA_LOG="$work/upstream-sha256s.txt"
: >"$UPSTREAM_SHA_LOG"

# ---------------------------------------------------------------- fetch/stage
# The CDN directory is MySQL-<major.minor>; the aarch64/x86_64 tarballs
# differ only in arch suffix.
url="https://dev.mysql.com/get/Downloads/MySQL-${version%.*}/mysql-${version}-linux-glibc2.28-${mysql_arch}.tar.xz"
fetch "$url" "$work/mysql.tar.xz" "${MYSQL_UPSTREAM_SHA256:-}"
tar -xJf "$work/mysql.tar.xz" -C "$work/src" --strip-components=1
src="$work/src"

for b in mysqld mysql mysqladmin; do
	cp -a "$src/bin/$b" "$prefix/bin/"
done
cp -a "$src/lib/plugin" "$src/lib/private" "$src/lib/mecab" "$prefix/lib/"
cp -a "$src/lib/"libmysqlclient.so* "$prefix/lib/"
cp -a "$src/share/." "$prefix/share/"
cp -a "$src/LICENSE" "$prefix/"

# ------------------------------------------------------------ runtime deps
# Install the packages providing the sonames ldd reports, copy each resolved
# library into lib/private/ (inside the RUNPATH), and keep only non-core
# libraries — libc, libstdc++, and friends are guaranteed on the runners.
sudo apt-get update
sudo apt-get install -y --no-install-recommends binutils xz-utils \
	libnuma1 libtinfo6 libncurses6
sudo apt-get install -y --no-install-recommends libaio1t64 ||
	sudo apt-get install -y --no-install-recommends libaio1

ldd "$prefix"/bin/* |
	sed -n 's|^[[:space:]]*\(lib[^ ]*\)[[:space:]]*=>[[:space:]]*\(/[^ ]*\).*|\1 \2|p' |
	sort -u |
	while read -r so path; do
		[ -n "$so" ] || continue
		case "$path" in "$prefix"/*) continue ;; esac
		case "$so" in
		libc.so.* | libm.so.* | libdl.so.* | libpthread.so.* | librt.so.* | \
			libresolv.so.* | libgcc_s.so.* | libstdc++.so.* | ld-linux-*.so.* | \
			libcrypt.so.*) ;;
		*) cp -L "$path" "$prefix/lib/private/$so" ;;
		esac
	done

# Oracle ships debug info inline (mysqld is ~460MB unstripped); strip it.
find "$prefix" -type f \( -name '*.so' -o -name '*.so.*' -o -path '*/bin/*' \) \
	-exec strip --strip-unneeded {} + 2>/dev/null || true

# ------------------------------------------------------------------- verify
# Every non-core soname must resolve inside the staging dir — a miss means a
# new dependency the bundling list above does not know yet.
unresolved=$(ldd "$prefix"/bin/* | grep 'not found' || true)
[ -z "$unresolved" ] || {
	echo "mysql-repack.sh: unresolved runtime deps:" >&2
	echo "$unresolved" >&2
	exit 1
}
leaked=$(ldd "$prefix"/bin/* |
	sed -n 's|^[[:space:]]*\(lib[^ ]*\)[[:space:]]*=>[[:space:]]*\(/[^ ]*\).*|\1 \2|p' |
	grep -vF "$prefix" |
	grep -vE 'libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libresolv\.so|libgcc_s\.so|libstdc\+\+|ld-linux|linux-vdso|libcrypt\.so' || true)
[ -z "$leaked" ] || {
	echo "mysql-repack.sh: non-core deps resolving outside the bundle:" >&2
	echo "$leaked" >&2
	exit 1
}

# -------------------------------------------------------- smoke: live server
data="$work/data"
"$prefix/bin/mysqld" --no-defaults --initialize-insecure --datadir="$data"
"$prefix/bin/mysqld" --no-defaults --datadir="$data" \
	--socket="$work/mysql.sock" --skip-networking --mysqlx=OFF \
	--pid-file="$work/mysqld.pid" &
i=60
while [ "$i" -gt 0 ]; do
	"$prefix/bin/mysqladmin" --no-defaults --socket="$work/mysql.sock" \
		-u root ping >/dev/null 2>&1 && break
	i=$((i - 1))
	sleep 1
done
"$prefix/bin/mysql" --no-defaults --socket="$work/mysql.sock" -u root -e \
	"SELECT VERSION(); CREATE DATABASE smoke_test; DROP DATABASE smoke_test;"
"$prefix/bin/mysqladmin" --no-defaults --socket="$work/mysql.sock" -u root shutdown

# -------------------------------------------------------------------- package
{
	echo "product=mysql"
	echo "version=$version"
	echo "platform=$platform"
	echo "upstream-url=$url"
	echo "recipe=repack of Oracle's Linux - Generic binaries: bin/{mysqld,mysql,mysqladmin} lib/{plugin,private,mecab,libmysqlclient.so*} share/ LICENSE; stripped; non-core runtime deps bundled into lib/private"
	echo "upstream-checksums:"
	cat "$UPSTREAM_SHA_LOG"
	true
} >"$prefix/BUILD-INFO.txt"

asset="$out/mysql-${version}-${platform}.tar.zst"
sh "$script_dir/pack.sh" "$work/stage" "$asset" opt

# Re-extract the archive and re-check the layout.
verify="$work/verify"
verify_extract "$asset" "$verify"
for f in bin/mysqld bin/mysql bin/mysqladmin share/english/errmsg.sys BUILD-INFO.txt; do
	[ -f "$verify/opt/mysql/$f" ] || {
		echo "mysql-repack.sh: packaged archive is missing $f" >&2
		exit 1
	}
done
echo "built $asset"
