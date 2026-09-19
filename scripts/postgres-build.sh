#!/bin/sh
# Build PostgreSQL + timescaledb + pgvector + VectorChord into a tar.zst rooted
# at opt/postgresql. Smoke test is a live throwaway cluster. Linux only.
# usage: postgres-build.sh <pg-version> <timescale-version> <pgvector-version> <vchord-version|none>
#   e.g. postgres-build.sh 18.6 2.29.2 0.8.6 1.1.1
# env:
#   POSTGRES_PLATFORM  asset platform suffix, e.g. linux-x64 (required)
#   POSTGRES_WORK      work dir (default .postgres-work)
#   Optional expected sha256 checks (skipped when unset):
#     POSTGRES_UPSTREAM_SHA256, TIMESCALEDB_UPSTREAM_SHA256,
#     PGVECTOR_UPSTREAM_SHA256, VCHORD_UPSTREAM_SHA256
set -eu
pg_version="${1:?usage: postgres-build.sh <pg> <timescale> <pgvector> <vchord|none>}"
ts_version="${2:?usage: postgres-build.sh <pg> <timescale> <pgvector> <vchord|none>}"
vec_version="${3:?usage: postgres-build.sh <pg> <timescale> <pgvector> <vchord|none>}"
vchord_version="${4:?usage: postgres-build.sh <pg> <timescale> <pgvector> <vchord|none>}"
platform="${POSTGRES_PLATFORM:?POSTGRES_PLATFORM must be set (e.g. linux-x64)}"
work="${POSTGRES_WORK:-$PWD/.postgres-work}"
out="$work/out"
prefix="$work/stage/opt/postgresql"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"
require_linux postgres-build.sh "VectorChord ships Linux binaries only, and the asset targets Linux runners"
rm -rf "$work"
mkdir -p "$prefix" "$out" "$work/src/postgresql" "$work/src/timescaledb" "$work/src/pgvector"

# ---------------------------------------------------------------- dependencies
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
	bison build-essential cmake flex libicu-dev libreadline-dev libssl-dev \
	lld pkg-config zlib1g-dev zstd
setup_linux_toolchain

UPSTREAM_SHA_LOG="$work/upstream-sha256s.txt"
: >"$UPSTREAM_SHA_LOG"

# ------------------------------------------------------------------ postgresql
fetch "https://ftp.postgresql.org/pub/source/v${pg_version}/postgresql-${pg_version}.tar.gz" \
	"$work/postgresql.tar.gz" "${POSTGRES_UPSTREAM_SHA256:-}"
tar -xzf "$work/postgresql.tar.gz" -C "$work/src/postgresql" --strip-components=1
(
	cd "$work/src/postgresql"
	./configure --prefix="$prefix" --with-icu --with-openssl
	make -s -j "$(ncpu)"
	make -s install
	make -s -C contrib/pgcrypto install
)

# ------------------------------------------------------------------ timescaledb
fetch "https://github.com/timescale/timescaledb/archive/refs/tags/${ts_version}.tar.gz" \
	"$work/timescaledb.tar.gz" "${TIMESCALEDB_UPSTREAM_SHA256:-}"
tar -xzf "$work/timescaledb.tar.gz" -C "$work/src/timescaledb" --strip-components=1
(
	cd "$work/src/timescaledb"
	PATH="$prefix/bin:$PATH" ./bootstrap -DREGRESS_CHECKS=OFF -DWARNINGS_AS_ERRORS=OFF
	make -s -C build -j "$(ncpu)"
	make -s -C build install
)

# --------------------------------------------------------------------- pgvector
fetch "https://github.com/pgvector/pgvector/archive/refs/tags/v${vec_version}.tar.gz" \
	"$work/pgvector.tar.gz" "${PGVECTOR_UPSTREAM_SHA256:-}"
tar -xzf "$work/pgvector.tar.gz" -C "$work/src/pgvector" --strip-components=1
make -s -C "$work/src/pgvector" -j "$(ncpu)" PG_CONFIG="$prefix/bin/pg_config"
make -s -C "$work/src/pgvector" install PG_CONFIG="$prefix/bin/pg_config"

# -------------------------------------------------------------------- vchord
# Prebuilt .deb keyed to the PG major. Pass `none` as the vchord arg to skip it.
pg_major=${pg_version%%.*}
vchord_preload=timescaledb
vchord_exts=""
if [ "$vchord_version" != none ]; then
	case "$(dpkg --print-architecture)" in
	amd64) deb_arch=amd64 ;;
	arm64) deb_arch=arm64 ;;
	*) echo "postgres-build.sh: unsupported dpkg arch $(dpkg --print-architecture)" >&2; exit 1 ;;
	esac
	fetch "https://github.com/tensorchord/VectorChord/releases/download/${vchord_version}/postgresql-${pg_major}-vchord_${vchord_version}-1_${deb_arch}.deb" \
		"$work/vchord.deb" "${VCHORD_UPSTREAM_SHA256:-}"
	dpkg-deb -x "$work/vchord.deb" "$work/vchord"
	cp -a "$work/vchord/usr/lib/postgresql/${pg_major}/lib/." "$prefix/lib/"
	cp -a "$work/vchord/usr/share/postgresql/${pg_major}/extension/." "$prefix/share/extension/"
	vchord_preload=timescaledb,vchord
	vchord_exts="CREATE EXTENSION IF NOT EXISTS vchord;"
fi

# -------------------------------------------------------------- smoke: live DB
data="$work/pgdata"
"$prefix/bin/initdb" -D "$data" --auth-host=trust --auth-local=trust --username=postgres
"$prefix/bin/pg_ctl" -D "$data" -l "$work/pg.log" \
	-o "-p 55432 -c fsync=off -c synchronous_commit=off -c full_page_writes=off -c autovacuum=off -c shared_preload_libraries=${vchord_preload}" \
	start
"$prefix/bin/pg_isready" -h 127.0.0.1 -p 55432
"$prefix/bin/psql" -h 127.0.0.1 -p 55432 -U postgres -d postgres -v ON_ERROR_STOP=1 \
	-c "CREATE EXTENSION IF NOT EXISTS timescaledb; CREATE EXTENSION IF NOT EXISTS vector; $vchord_exts"
extension_list=$("$prefix/bin/psql" -h 127.0.0.1 -p 55432 -U postgres -d postgres -Atc \
	"SELECT extname || '=' || extversion FROM pg_extension ORDER BY 1")
echo "$extension_list"
for want in timescaledb vector; do
	echo "$extension_list" | grep -q "^${want}=" || {
		echo "postgres-build.sh: extension ${want} missing after CREATE" >&2
		"$prefix/bin/pg_ctl" -D "$data" stop -m fast || true
		exit 1
	}
done
if [ "$vchord_version" != none ]; then
	echo "$extension_list" | grep -q '^vchord=' || {
		echo "postgres-build.sh: extension vchord missing after CREATE" >&2
		"$prefix/bin/pg_ctl" -D "$data" stop -m fast || true
		exit 1
	}
fi
"$prefix/bin/pg_ctl" -D "$data" stop -m fast

# -------------------------------------------------------------------- package
{
	echo "product=postgres"
	echo "version=${pg_version}-timescale${ts_version}-pgvector${vec_version}-vchord${vchord_version}"
	echo "platform=$platform"
	echo "configure=--with-icu --with-openssl (plus contrib/pgcrypto)"
	echo "timescaledb-bootstrap=-DREGRESS_CHECKS=OFF -DWARNINGS_AS_ERRORS=OFF"
	echo "cc=$(${CC:-cc} --version | head -n 1)"
	echo "upstream-checksums:"
	cat "$UPSTREAM_SHA_LOG"
	true
} >"$prefix/BUILD-INFO.txt"

asset="$out/postgres-${pg_version}-timescale${ts_version}-pgvector${vec_version}-vchord${vchord_version}-${platform}.tar.zst"
sh "$script_dir/pack.sh" "$work/stage" "$asset" opt

# Re-extract the archive and re-check the layout.
verify="$work/verify"
verify_extract "$asset" "$verify"
[ -f "$verify/opt/postgresql/BUILD-INFO.txt" ] || {
	echo "postgres-build.sh: packaged archive is missing BUILD-INFO.txt" >&2
	exit 1
}
[ -x "$verify/opt/postgresql/bin/postgres" ] || {
	echo "postgres-build.sh: packaged archive is missing bin/postgres" >&2
	exit 1
}
[ -f "$verify/opt/postgresql/share/extension/timescaledb.control" ] || {
	echo "postgres-build.sh: packaged archive is missing timescaledb extension files" >&2
	exit 1
}
echo "built $asset"
