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
#                   llama-embedding: bNNNN     e.g. b10819
#                   oci-mirror: <name>:<tag>   e.g. cilium:v1.20.1
#                   (empty rebuilds every image in oci-images.txt at latest)
#   GH_TOKEN, GITHUB_REPOSITORY, GITHUB_OUTPUT
set -eu
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
out="${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"
force_product="${FORCE_PRODUCT:-}"
force_version="${FORCE_VERSION:-}"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"

case "$force_product" in
"" | aws-lc | bun | zlib-ng | postgres | valkey | clickhouse | pebble | typesense | zstd | libgit2 | sqlite-vec | llama-embedding | oci-mirror) ;;
*) echo "check.sh: unknown product '$force_product'" >&2; exit 1 ;;
esac

force_oci_name=
force_oci_tag=
if [ "$force_product" = oci-mirror ] && [ -n "$force_version" ]; then
	case "$force_version" in
	*:*) ;;
	*)
		echo "check.sh: forced oci-mirror version must be <name>:<tag> (e.g. cilium:v1.20.1)" >&2
		exit 1 ;;
	esac
	force_oci_name="${force_version%%:*}"
	force_oci_tag="${force_version#*:}"
	case "$force_oci_name" in '' | *[!a-z0-9-]*)
		echo "check.sh: invalid oci-mirror name in '$force_version'" >&2
		exit 1 ;;
	esac
	case "$force_oci_tag" in '' | [.-]* | *[!a-zA-Z0-9_.-]*)
		echo "check.sh: forced oci-mirror version must be <name>:<tag> (e.g. cilium:v1.20.1)" >&2
		exit 1 ;;
	esac
fi

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

# ---------------------------------------------------------------- sqlite-vec
# Upstream publishes loadable-extension tarballs; the repack only mirrors them.
decide sqlite-vec "$(force_or sqlite-vec "$(latest_gh asg017/sqlite-vec 's/^v//')")"

# ------------------------------------------------------------- llama-embedding
# The version is a bNNNN tag, verbatim (tag llama-embedding/vbNNNN). Upstream
# marks every b-build a prerelease, so releases/latest resolves to a semver
# tag that ships no bin assets — take the newest b* release carrying all three
# bin tarballs instead.
if [ "$force_product" = llama-embedding ] && [ -n "$force_version" ]; then
	llama_v=$force_version
else
	llama_v=$(gh api "repos/ggml-org/llama.cpp/releases?per_page=30" --jq '
		[.[] | select(.tag_name | startswith("b"))
		 | select([.assets[].name | select(test("-bin-(ubuntu-x64|ubuntu-arm64|macos-arm64)\\.tar\\.gz$"))]
			| unique | length == 3)
		 | .tag_name][0]')
fi
case "$llama_v" in b*) ;; *) llama_v="b$llama_v" ;; esac
decide llama-embedding "$llama_v"

# --------------------------------------------------------------- oci mirrors
# zstd:chunked repacks of upstream platform images. scripts/oci-images.txt
# lists "<name> <registry/repo> <gh repo> <sed>": "latest" is the upstream
# GitHub latest release tag transformed by <sed> ("-" or empty = no transform).
# Registry tag listings are unordered and paginated (ghcr caps tags/list at
# 100 per page), so they can't resolve latest — the GH release is the source
# of truth, and the tag is then probed on the registry. A fresh upstream
# release whose image is not pushed yet is skipped until the next run.
# Output is a build matrix (all arches are handled in one skopeo copy).
oci_file="$script_dir/oci-images.txt"
oci_matrix=
oci_names=
oci_build=false
oci_matched_force=false
while read -r oci_name oci_repo oci_gh oci_sed || [ -n "$oci_name" ]; do
	case "$oci_name" in '' | '#'*) continue ;; esac
	case " $oci_names " in
	*" $oci_name "*)
		echo "check.sh: duplicate name in oci-images.txt: $oci_name" >&2
		exit 1 ;;
	esac
	oci_names="$oci_names $oci_name"
	[ -n "$oci_repo" ] && [ -n "$oci_gh" ] || {
		echo "check.sh: bad oci-images.txt line: '$oci_name $oci_repo $oci_gh $oci_sed'" >&2
		exit 1
	}
	forced=false
	if [ "$oci_name" = "$force_oci_name" ]; then
		oci_tag=$force_oci_tag
		forced=true
		oci_matched_force=true
	else
		case "$oci_sed" in '' | -) oci_sed='s/$//' ;; esac
		oci_tag=$(latest_gh "$oci_gh" "$oci_sed")
		[ "$force_product" = oci-mirror ] && [ -z "$force_oci_name" ] && forced=true
	fi
	oci_ver="${oci_tag#v}"
	if [ "$forced" = true ] ||
		! printf '%s\n' "$existing_tags" | grep -qxF "oci-$oci_name/v$oci_ver"; then
		ensure_cmds skopeo
		if skopeo inspect --raw "docker://$oci_repo:$oci_tag" >/dev/null 2>&1; then
			entry=$(printf '{"name":"%s","ref":"%s","version":"%s"}' \
				"$oci_name" "$oci_repo:$oci_tag" "$oci_ver")
			oci_matrix="${oci_matrix:+$oci_matrix,}$entry"
			oci_build=true
			echo "oci-$oci_name: $oci_repo:$oci_tag build=true"
		elif [ "$forced" = true ]; then
			echo "check.sh: image not on registry: $oci_repo:$oci_tag" >&2
			exit 1
		else
			echo "oci-$oci_name: $oci_repo:$oci_tag not on registry yet — skipping"
		fi
	else
		echo "oci-$oci_name: oci-$oci_name/v$oci_ver build=false"
	fi
done <"$oci_file"
if [ -n "$force_oci_name" ] && [ "$oci_matched_force" = false ]; then
	echo "check.sh: '$force_oci_name' is not in oci-images.txt" >&2
	exit 1
fi
printf 'oci_build=%s\noci_matrix={"include":[%s]}\n' "$oci_build" "$oci_matrix" >>"$out"
