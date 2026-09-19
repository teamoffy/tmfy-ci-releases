#!/bin/sh
# Resolve the target version and build decision for every product.
# Emits <product>_version/_build outputs plus component versions for the
# multi-component products. A forced product always rebuilds; others
# build only when the tag doesn't exist yet.
# env:
#   FORCE_PRODUCT   optional product to force-rebuild (validated)
#   FORCE_VERSION   optional version for the forced product; latest if empty.
#                   postgres: pg/ts/vec/vchord  e.g. 18.6/2.29.2/0.8.6/1.1.1
#                   valkey:   server/bloom     e.g. 9.1.2/1.0.1
#                   libgit2:  libgit2/libssh2  e.g. 1.9.7/1.11.1
#   GH_TOKEN, GITHUB_REPOSITORY, GITHUB_OUTPUT
set -eu
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
out="${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"
force_product="${FORCE_PRODUCT:-}"
force_version="${FORCE_VERSION:-}"

case "$force_product" in
"" | aws-lc | bun | zlib-ng | postgres | valkey | clickhouse | pebble | typesense | zstd | libgit2) ;;
*) echo "check.sh: unknown product '$force_product'" >&2; exit 1 ;;
esac

latest_gh() { # <owner/repo> <sed expr>
	gh api "repos/$1/releases/latest" --jq '.tag_name' | sed "$2"
}

# List all release tags once up front: a per-tag lookup can't distinguish
# "missing" from an API error, and a spurious build would replace good assets.
existing_tags=$(gh api "repos/$repo/releases?per_page=100" --paginate --jq '.[].tag_name')

decide() { # <product> <version>
	p=$1
	v=$2
	# $(...) pipelines can yield empty strings without tripping set -e.
	[ -n "$v" ] || {
		echo "check.sh: failed to resolve a version for $p" >&2
		exit 1
	}
	tag="$p/v$v"
	if [ "$p" = "$force_product" ] || ! printf '%s\n' "$existing_tags" | grep -qxF "$tag"; then
		build=true
	else
		build=false
	fi
	sanitized=$(printf '%s' "$p" | tr '-' '_')
	printf '%s_version=%s\n%s_build=%s\n' "$sanitized" "$v" "$sanitized" "$build" >>"$out"
	echo "$p: $tag build=$build"
}

force_or() { # <product> <upstream-latest>  -> the version to build
	if [ "$1" = "$force_product" ] && [ -n "$force_version" ]; then
		printf '%s\n' "$force_version"
	else
		printf '%s\n' "$2"
	fi
}

# -------------------------------------------------------------------- aws-lc
decide aws-lc "$(force_or aws-lc "$(latest_gh aws/aws-lc 's/^v//')")"

# ----------------------------------------------------------------------- bun
decide bun "$(force_or bun "$(latest_gh oven-sh/bun 's/^bun-v//')")"

# ------------------------------------------------------------------- zlib-ng
decide zlib-ng "$(force_or zlib-ng "$(latest_gh zlib-ng/zlib-ng 's/^v//')")"

# ------------------------------------------------------------------ postgres
# PG majors past 18 need a new VectorChord .deb target; bump via forced version.
if [ "$force_product" = postgres ] && [ -n "$force_version" ]; then
	slashes=$(printf '%s' "$force_version" | tr -cd '/' | wc -c | tr -d ' ')
	if [ "$slashes" != 3 ]; then
		echo "check.sh: forced postgres version must be pg/ts/vec/vchord (got '$force_version')" >&2
		exit 1
	fi
	pg=${force_version%%/*}
	rest=${force_version#*/}
	ts=${rest%%/*}
	rest=${rest#*/}
	vec=${rest%%/*}
	vchord=${rest##*/}
else
	pg=$(curl -fsSL https://ftp.postgresql.org/pub/source/ |
		grep -oE 'v18\.[0-9]+/' | tr -d 'v/' | sort -uV | tail -1)
	ts=$(latest_gh timescale/timescaledb 's/^v//')
	# pgvector publishes tags but no GitHub releases.
	vec=$(git ls-remote --tags https://github.com/pgvector/pgvector 'refs/tags/v*' |
		sed 's|.*refs/tags/v||' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -uV | tail -1)
	vchord=$(latest_gh tensorchord/VectorChord 's/^v//')
fi
[ -n "$pg" ] && [ -n "$ts" ] && [ -n "$vec" ] && [ -n "$vchord" ] || {
	echo "check.sh: unresolved postgres component(s): pg='$pg' ts='$ts' vec='$vec' vchord='$vchord'" >&2
	exit 1
}
printf 'postgres_pg=%s\npostgres_ts=%s\npostgres_vec=%s\npostgres_vchord=%s\n' \
	"$pg" "$ts" "$vec" "$vchord" >>"$out"
decide postgres "${pg}-timescale${ts}-pgvector${vec}-vchord${vchord}"

# -------------------------------------------------------------------- valkey
# Binaries live on download.valkey.io (GitHub releases are source-only); track
# stable git tags — the build fails loudly if the noble tarball is missing.
if [ "$force_product" = valkey ] && [ -n "$force_version" ]; then
	slashes=$(printf '%s' "$force_version" | tr -cd '/' | wc -c | tr -d ' ')
	if [ "$slashes" != 1 ]; then
		echo "check.sh: forced valkey version must be server/bloom (got '$force_version')" >&2
		exit 1
	fi
	server=${force_version%%/*}
	bloom=${force_version##*/}
else
	server=$(git ls-remote --tags https://github.com/valkey-io/valkey 'refs/tags/*' |
		sed 's|.*refs/tags/||' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -uV | tail -1)
	bloom=$(latest_gh valkey-io/valkey-bloom 's/^v//')
fi
[ -n "$server" ] && [ -n "$bloom" ] || {
	echo "check.sh: unresolved valkey component(s): server='$server' bloom='$bloom'" >&2
	exit 1
}
printf 'valkey_server=%s\nvalkey_bloom=%s\n' "$server" "$bloom" >>"$out"
decide valkey "${server}-bloom${bloom}"

# ---------------------------------------------------------------- clickhouse
# LTS tags only, resolved from git refs (latest-release APIs can't pick the
# newest LTS).
if [ "$force_product" = clickhouse ] && [ -n "$force_version" ]; then
	ch_version=$(printf '%s' "$force_version" | sed 's/^v//; s/-lts$//')
else
	ch_version=$(git ls-remote --tags https://github.com/ClickHouse/ClickHouse 'refs/tags/*-lts' |
		sed 's|.*refs/tags/v||; s|-lts$||' |
		grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -uV | tail -1)
fi
decide clickhouse "$ch_version"

# -------------------------------------------------------------------- pebble
decide pebble "$(force_or pebble "$(latest_gh letsencrypt/pebble 's/^v//')")"

# ----------------------------------------------------------------- typesense
decide typesense "$(force_or typesense "$(latest_gh typesense/typesense 's/^v//')")"

# ---------------------------------------------------------------------- zstd
decide zstd "$(force_or zstd "$(latest_gh facebook/zstd 's/^v//')")"

# ------------------------------------------------------------------- libgit2
# Bundled libssh2 is the SSH provider; track both so a libssh2 bump rebuilds.
if [ "$force_product" = libgit2 ] && [ -n "$force_version" ]; then
	slashes=$(printf '%s' "$force_version" | tr -cd '/' | wc -c | tr -d ' ')
	if [ "$slashes" != 1 ]; then
		echo "check.sh: forced libgit2 version must be libgit2/libssh2 (got '$force_version')" >&2
		exit 1
	fi
	lg=${force_version%%/*}
	ssh2=${force_version##*/}
else
	lg=$(latest_gh libgit2/libgit2 's/^v//')
	ssh2=$(latest_gh libssh2/libssh2 's/^libssh2-//')
fi
[ -n "$lg" ] && [ -n "$ssh2" ] || {
	echo "check.sh: unresolved libgit2 component(s): libgit2='$lg' libssh2='$ssh2'" >&2
	exit 1
}
printf 'libgit2_ver=%s\nlibgit2_ssh2=%s\n' "$lg" "$ssh2" >>"$out"
decide libgit2 "${lg}-libssh2-${ssh2}"
