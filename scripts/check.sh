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
#                   flatcar-zfs-sysext: flatcar/zfs  e.g. 4593.2.5/2.4.4
#                   oci-mirror: <name>:<tag>   e.g. cilium:v1.20.1
#                   oci-<name>: <tag>          e.g. product=oci-cilium
#                   ci-tools:   <name>:<tag>   e.g. kubectl:v1.36.4
#                   <tool name>: <tag>          e.g. product=kubectl
#                   (empty rebuilds every image/tool in the list at latest)
#   GH_TOKEN, GITHUB_REPOSITORY, GITHUB_OUTPUT
set -eu
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
out="${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"
force_product="${FORCE_PRODUCT:-}"
force_version="${FORCE_VERSION:-}"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"

manifest_names() { # <file> -> first column of each non-comment line
	awk 'NF && $1 !~ /^#/ { print $1 }' "$1"
}

force_oci_name=
force_oci_tag=
force_tool=
force_tool_tag=
force_all_tools=false
case "$force_product" in
"" | aws-lc | bun | zlib-ng | postgres | valkey | clickhouse | pebble | typesense | zstd | libgit2 | sqlite-vec | llama-embedding | k3s | flatcar | flatcar-zfs-sysext) ;;
oci-mirror)
	if [ -n "$force_version" ]; then
		case "$force_version" in
		*:*) ;;
		*)
			echo "check.sh: forced oci-mirror version must be <name>:<tag> (e.g. cilium:v1.20.1)" >&2
			exit 1 ;;
		esac
		force_oci_name="${force_version%%:*}"
		force_oci_tag="${force_version#*:}"
	fi ;;
oci-*)
	# oci-<name> forces that one image; the version input is the tag.
	force_oci_name="${force_product#oci-}"
	force_oci_tag="$force_version" ;;
ci-tools)
	# <name>:<tag> forces that tool; an empty version rebuilds the whole list.
	if [ -n "$force_version" ]; then
		case "$force_version" in
		*:*) ;;
		*)
			echo "check.sh: forced ci-tools version must be <name>:<tag> (e.g. kubectl:v1.36.4)" >&2
			exit 1 ;;
		esac
		force_tool="${force_version%%:*}"
		force_tool_tag="${force_version#*:}"
	else
		force_all_tools=true
	fi ;;
*)
	# ci-tools product names are dynamic: a manifest name forces that tool.
	if manifest_names "$script_dir/ci-tools.txt" | grep -qx "$force_product"; then
		force_tool=$force_product
		force_tool_tag=$force_version
	else
		echo "check.sh: unknown product '$force_product'" >&2
		exit 1
	fi ;;
esac
if [ -n "$force_oci_name" ]; then
	case "$force_oci_name" in '' | *[!a-z0-9-]*)
		echo "check.sh: invalid oci-mirror name in '$force_version'" >&2
		exit 1 ;;
	esac
fi
if [ -n "$force_oci_tag" ]; then
	case "$force_oci_tag" in '' | [.-]* | *[!a-zA-Z0-9_.-]*)
		echo "check.sh: invalid oci-mirror tag '$force_oci_tag'" >&2
		exit 1 ;;
	esac
fi
if [ -n "$force_tool_tag" ]; then
	case "$force_tool_tag" in '' | *[!a-zA-Z0-9_.-]*)
		echo "check.sh: invalid ci-tools tag '$force_tool_tag'" >&2
		exit 1 ;;
	esac
	# All tracked tools tag v-prefixed releases; accept a bare version too.
	case "$force_tool_tag" in v* | RELEASE*) ;; *) force_tool_tag="v$force_tool_tag" ;; esac
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

# -------------------------------------------------------------------- k3s
# Node binaries + zstd airgap images, mirrored verbatim from k3s-io releases —
# fetched at every node boot, the same per-node-pull class as the oci mirrors.
decide k3s "$(force_or k3s "$(latest_gh k3s-io/k3s 's/^v//')")"

# ------------------------------------------------------------------ flatcar
# Public release artifacts under <channel>.release.flatcar-linux.net, mirrored
# for pin durability — the CDN drops old versions while tea's pins keep
# referencing them. "latest" = the channel's current release, read from its
# version.txt; there is no releases API.
flatcar_latest() {
	curl -fsSL --retry 3 \
		"https://${1:-stable}.release.flatcar-linux.net/amd64-usr/current/version.txt" |
		sed -n 's/^FLATCAR_VERSION=//p'
}
flatcar_latest_v=$(flatcar_latest stable)
flatcar_v=$(force_or flatcar "$flatcar_latest_v")
printf '%s\n' "$flatcar_v" | grep -Eq '^[0-9]+(\.[0-9]+)+$' || {
	echo "check.sh: invalid Flatcar version '$flatcar_v'" >&2
	exit 1
}
decide flatcar "$flatcar_v"

# ------------------------------------------------------ flatcar-zfs-sysext
# OpenZFS built as a systemd-sysext inside the matching Flatcar developer
# container. The combo version is <flatcar>-zfs<zfs>; the Flatcar half tracks
# the same channel resolution as the flatcar product.
if [ "$force_product" = flatcar-zfs-sysext ] && [ -n "$force_version" ]; then
	slashes=$(printf '%s' "$force_version" | tr -cd '/' | wc -c | tr -d ' ')
	if [ "$slashes" != 1 ]; then
		echo "check.sh: forced flatcar-zfs-sysext version must be flatcar/zfs (got '$force_version')" >&2
		exit 1
	fi
	sysext_flatcar=${force_version%%/*}
	sysext_zfs=${force_version##*/}
else
	sysext_flatcar=$flatcar_latest_v
	sysext_zfs=$(latest_gh openzfs/zfs 's/^zfs-//')
fi
[ -n "$sysext_flatcar" ] && [ -n "$sysext_zfs" ] || {
	echo "check.sh: unresolved flatcar-zfs-sysext components: flatcar='$sysext_flatcar' zfs='$sysext_zfs'" >&2
	exit 1
}
printf '%s\n' "$sysext_flatcar" "$sysext_zfs" |
	grep -Eqv '^[0-9]+(\.[0-9]+)+$' && {
	echo "check.sh: invalid flatcar-zfs-sysext version '$sysext_flatcar/$sysext_zfs'" >&2
	exit 1
}
printf 'flatcar_zfs_sysext_flatcar=%s\nflatcar_zfs_sysext_zfs=%s\n' \
	"$sysext_flatcar" "$sysext_zfs" >>"$out"
decide flatcar-zfs-sysext "${sysext_flatcar}-zfs${sysext_zfs}"

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
		forced=true
		oci_matched_force=true
	elif [ "$force_product" = oci-mirror ] && [ -z "$force_oci_name" ]; then
		forced=true
	fi
	case "$oci_sed" in '' | -) oci_sed='s/$//' ;; esac
	if [ "$oci_name" = "$force_oci_name" ] && [ -n "$force_oci_tag" ]; then
		oci_tag=$force_oci_tag
	else
		oci_tag=$(latest_gh "$oci_gh" "$oci_sed")
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

# ----------------------------------------------------------------- ci tools
# Verified mirrors of small public binaries that tea pins by
# sha256 in downloads.sha256 / @moffy/versions. ci-tools.txt lists
# "<name> <gh-repo> <x64-url> <arm64-url> <mode>"; latest is the repo's GitHub
# latest release. Output is a build matrix, one cell per missing tool.
tools_file="$script_dir/ci-tools.txt"
tools_matrix=
tools_names=
tools_build=false
tools_matched_force=false
while read -r tool_name tool_repo tool_u64 tool_ua64 tool_mode || [ -n "$tool_name" ]; do
	case "$tool_name" in '' | '#'*) continue ;; esac
	case " $tools_names " in
	*" $tool_name "*)
		echo "check.sh: duplicate name in ci-tools.txt: $tool_name" >&2
		exit 1 ;;
	esac
	tools_names="$tools_names $tool_name"
	[ -n "$tool_repo" ] && [ -n "$tool_u64" ] && [ -n "$tool_ua64" ] && [ -n "$tool_mode" ] || {
		echo "check.sh: bad ci-tools.txt line: '$tool_name $tool_repo $tool_u64 $tool_ua64 $tool_mode'" >&2
		exit 1
	}
	forced=false
	tool_tag=
	if [ -n "$force_tool" ] && [ "$tool_name" = "$force_tool" ]; then
		forced=true
		tools_matched_force=true
		tool_tag=$force_tool_tag
	elif [ "$force_all_tools" = true ]; then
		forced=true
	fi
	[ -n "$tool_tag" ] || tool_tag=$(latest_gh "$tool_repo" 's/$//')
	tool_ver="${tool_tag#v}"
	if [ "$forced" = true ] ||
		! printf '%s\n' "$existing_tags" | grep -qxF "$tool_name/v$tool_ver"; then
		entry=$(printf '{"name":"%s","tag":"%s","version":"%s"}' \
			"$tool_name" "$tool_tag" "$tool_ver")
		tools_matrix="${tools_matrix:+$tools_matrix,}$entry"
		tools_build=true
		echo "$tool_name: $tool_tag build=true"
	else
		echo "$tool_name: $tool_name/v$tool_ver build=false"
	fi
done <"$tools_file"
if [ -n "$force_tool" ] && [ "$tools_matched_force" = false ]; then
	echo "check.sh: '$force_tool' is not in ci-tools.txt" >&2
	exit 1
fi
printf 'tools_build=%s\ntools_matrix={"include":[%s]}\n' "$tools_build" "$tools_matrix" >>"$out"
