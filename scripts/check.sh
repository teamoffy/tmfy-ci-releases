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
#                   graalvm:  must equal graalvm.txt's pin (GDS has no latest)
#                   flatcar-zfs-sysext: flatcar/zfs  e.g. 4593.2.5/2.4.4
#                   oci-mirror: <name>:<tag>   e.g. cilium:v1.20.1
#                   oci-<name>: <tag>          e.g. product=oci-cilium
#                   ci-tools:   <name>:<tag>   e.g. kubectl:v1.36.4
#                   <tool name>: <tag>          e.g. product=kubectl
#                   (empty rebuilds every image/tool in the list at latest)
#                   pulumi-plugins:            product=pulumi-plugins
#                   pulumi-plugin-<name>:      product=pulumi-plugin-aws
#                   (versions are pinned in pulumi-plugins.txt; a version
#                   input must equal the pin)
#   GH_TOKEN, GITHUB_REPOSITORY, GITHUB_OUTPUT, GITHUB_EVENT_NAME
#                   (schedule applies the 12h release bake-in window;
#                   workflow_dispatch and local runs bypass it)
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
force_pulumi_plugin=
force_all_pulumi_plugins=false
case "$force_product" in
"" | aws-lc | bun | graalvm | zlib-ng | postgres | mysql | valkey | clickhouse | pebble | typesense | zstd | libgit2 | sqlite-vec | llama-embedding | k3s | k3s-system | flatcar | flatcar-zfs-sysext) ;;
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
pulumi-plugins)
	# Every pin rebuilds; the versions live in pulumi-plugins.txt, so a
	# version input is meaningless here.
	if [ -n "$force_version" ]; then
		echo "check.sh: product=pulumi-plugins rebuilds every pin in pulumi-plugins.txt; use product=pulumi-plugin-<name> for one" >&2
		exit 1
	fi
	force_all_pulumi_plugins=true ;;
pulumi-plugin-*)
	# pulumi-plugin-<name> forces that provider; a version input must equal
	# the manifest pin.
	force_pulumi_plugin="${force_product#pulumi-plugin-}" ;;
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
if [ -n "$force_pulumi_plugin" ]; then
	case "$force_pulumi_plugin" in '' | *[!a-z0-9-]*)
		echo "check.sh: invalid pulumi plugin name in '$force_product'" >&2
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

# ------------------------------------------------------- release bake-in
# Scheduled runs only mirror upstream releases at least 12h old: a pulled or
# compromised release usually disappears within hours, so the window keeps
# the mirrors from racing it. Resolution falls back to the previous release
# where the source has history; Flatcar's channel does not, so it defers.
# workflow_dispatch and local runs bypass the window (the escape route), and
# stacks.txt pins are human-vetted, so they are exempt too.
if [ "${GITHUB_EVENT_NAME:-}" = schedule ]; then
	release_min_age=43200 # 12h
else
	release_min_age=0
fi
release_cutoff=$(($(date +%s) - release_min_age))
cutoff_ymd=$(date -u -d "@$release_cutoff" +%F 2>/dev/null ||
	date -u -r "$release_cutoff" +%F)
# jq predicate over gh api release objects: published_at clears the window.
jq_aged="(.published_at | fromdateiso8601) <= $release_cutoff"

# latest_gh <owner/repo> <sed expr> — upstream's newest release. GitHub's
# releases/latest resolves by release line, so a backport patch on an older
# line does not take over (creation order would); it is used whenever it
# clears the bake-in window. Otherwise the highest-version release that
# clears the window wins — the previous line, not the most recent patch.
latest_gh() {
	_le_new=$(gh api "repos/$1/releases/latest" \
		--jq '"\(.tag_name) \(.published_at | fromdateiso8601)"' 2>/dev/null) || true
	if [ -n "$_le_new" ] && [ "${_le_new##* }" -le "$release_cutoff" ]; then
		printf '%s\n' "${_le_new%% *}" | sed "$2"
		return 0
	fi
	gh api "repos/$1/releases?per_page=30" \
		--jq '.[] | select((.draft | not) and (.prerelease | not) and .published_at)
			| "\(.tag_name) \(.published_at | fromdateiso8601)"' |
	while read -r _le_tag _le_pub; do
		[ "$_le_pub" -le "$release_cutoff" ] || continue
		printf '%s\n' "$_le_tag"
	done | sort -Vr | head -1 | sed "$2"
}

# to_epoch <date> — GNU date -d first, then BSD date -j for the two upstream
# formats: HTTP Last-Modified and the Apache index's DD-Mon-YYYY.
to_epoch() {
	_te_d=$(printf '%s' "$1" | tr '-' ' ')
	date -d "$_te_d" +%s 2>/dev/null && return 0
	date -j -f "%a, %d %b %Y %H:%M:%S GMT" "$1" +%s 2>/dev/null ||
		date -j -f "%d %b %Y %H:%M" "$_te_d" +%s 2>/dev/null
}

# tag_epoch <owner/repo> <tag> — when a git tag was cut: the tagger date for
# annotated tags, the tagged commit's committer date for lightweight ones.
tag_epoch() {
	_te_obj=$(gh api "repos/$1/git/ref/tags/$2" --jq '.object.url' 2>/dev/null) || return 1
	gh api "$_te_obj" --jq '(.tagger.date // .committer.date) | fromdateiso8601' 2>/dev/null
}

# latest_tag <owner/repo> <ref-glob> <tag-regex> <sed> — newest matching git
# tag whose date clears the window. ls-remote carries no dates, so the 15
# newest candidates are dated via the API, newest first.
latest_tag() {
	git ls-remote --tags "https://github.com/$1" "$2" |
	sed 's|.*refs/tags/||' | grep -E "$3" | sort -uVr | head -15 |
	while IFS= read -r _lt_tag; do
		_lt_e=$(tag_epoch "$1" "$_lt_tag") || continue
		[ -n "$_lt_e" ] && [ "$_lt_e" -le "$release_cutoff" ] || continue
		printf '%s\n' "$_lt_tag" | sed "$4"
		break
	done
}

# tool_latest <repo> — upstream tag a ci-tools.txt row builds. "Latest" is
# the repo's latest GitHub release, except repos whose newest release line
# isn't what we ship: nodejs/node's latest is the Current line, not LTS.
tool_latest() {
	case "$1" in
	nodejs/node)
		# dist/index.json is newest-first; the first entry with an lts
		# codename inside the bake-in window is the current LTS point release.
		ensure_cmds curl jq
		curl -fsSL --retry 3 --max-time 20 https://nodejs.org/dist/index.json |
			jq -r '[.[] | select(.lts != false) | select(.date <= "'"$cutoff_ymd"'")][0].version' ;;
	*) latest_gh "$1" 's/$//' ;;
	esac
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

# Emit {"version":...} matrix cells on stdout for every candidate whose
# release tag is missing (the forced version always emits). Progress lines go
# to stderr so the function can be used in $(...).
ver_matrix() { # <product> <forced-ver> <candidates...>
	_vm_p=$1
	_vm_forced=$2
	shift 2
	_vm_m=
	_vm_seen=
	for _vm_v in "$@"; do
		case " $_vm_seen " in
		*" $_vm_v "*) continue ;;
		esac
		_vm_seen="$_vm_seen $_vm_v"
		if [ "$_vm_v" = "$_vm_forced" ] ||
			! printf '%s\n' "$existing_tags" | grep -qxF "$_vm_p/v$_vm_v"; then
			_vm_m="${_vm_m:+$_vm_m,}{\"version\":\"$_vm_v\"}"
			echo "$_vm_p: v$_vm_v build=true" >&2
		else
			echo "$_vm_p: v$_vm_v build=false" >&2
		fi
	done
	printf '%s' "$_vm_m"
}

oci_probe() { # <repo:tag> — is this image actually pushed?
	skopeo inspect --raw --retry-times 3 "docker://$1" >/dev/null 2>&1
}

# Print the newest image tag that is actually on the registry. Upstream's
# latest release is preferred, but a GitHub release can precede (or skip)
# registry promotion — an unpromoted release is not eligible, so fall back
# through the newest releases (version order) to the newest servable tag.
# Empty output = nothing servable.
latest_eligible_oci() { # <gh-repo> <sed> <registry-repo>
	_le_tag=$(latest_gh "$1" "$2")
	# No latest release: nothing to fall back to. Empty output, not a
	# failure — the caller reports the skip (a nonzero return here would
	# abort the whole run under set -e).
	[ -n "$_le_tag" ] || return 0
	oci_probe "$3:$_le_tag" && {
		printf '%s\n' "$_le_tag"
		return 0
	}
	gh release list --repo "$1" --limit 10 --json tagName,isPrerelease,publishedAt \
		--jq '.[] | select(.isPrerelease | not)
			| "\(.tagName) \(.publishedAt | fromdateiso8601)"' 2>/dev/null |
	sort -Vr |
	while read -r _le_rel _le_pub; do
		[ "$_le_pub" -le "$release_cutoff" ] || continue
		_le_img=$(printf '%s' "$_le_rel" | sed "$2")
		[ "$_le_img" = "$_le_tag" ] && continue
		oci_probe "$3:$_le_img" || continue
		printf '%s\n' "$_le_img"
		break
	done
}

# Probe an image ref on the registry and queue a build cell for it. Skips
# cells already queued (stack rows emit first). Returns nonzero when the tag
# is not on the registry — the caller decides whether that's fatal.
emit_oci() { # <name> <repo:tag> <version>
	case " $oci_cell_keys " in *" $1:$3 "*) return 0 ;; esac
	oci_probe "$2" || return 1
	oci_cell_keys="$oci_cell_keys $1:$3"
	oci_matrix="${oci_matrix:+$oci_matrix,}$(printf \
		'{"name":"%s","ref":"%s","version":"%s"}' "$1" "$2" "$3")"
	oci_build=true
	echo "oci-$1: $2 build=true"
}

# -------------------------------------------------------------------- aws-lc
decide aws-lc "$(force_or aws-lc "$(latest_gh aws/aws-lc 's/^v//')")"

# ----------------------------------------------------------------------- bun
decide bun "$(force_or bun "$(latest_gh oven-sh/bun 's/^bun-v//')")"

# ------------------------------------------------------------------- graalvm
# Oracle GDS exposes no "latest" — artifact ids are immutable per bundle and
# pinned (with sha256s) in graalvm.txt, so the manifest IS the version source.
# A forced version must equal it: repack can only build the pinned artifacts.
graalvm_v=$(awk 'NF && $1 !~ /^#/ && $1 == "version" { print $2; exit }' \
	"$script_dir/graalvm.txt")
[ -n "$graalvm_v" ] || {
	echo "check.sh: no version row in scripts/graalvm.txt" >&2
	exit 1
}
if [ "$force_product" = graalvm ] && [ -n "$force_version" ] && [ "$force_version" != "$graalvm_v" ]; then
	echo "check.sh: graalvm artifacts are pinned in graalvm.txt (currently $graalvm_v) — update the manifest to bump" >&2
	exit 1
fi
decide graalvm "$graalvm_v"

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
	# The source index dates every v18.x directory (Apache listing format).
	pg=$(curl -fsSL https://ftp.postgresql.org/pub/source/ |
		grep -oE 'v18\.[0-9]+/</a> +[0-9]{2}-[A-Za-z]{3}-[0-9]{4} [0-9]{2}:[0-9]{2}' |
		while read -r _pg_ver _pg_d _pg_t; do
			_pg_e=$(to_epoch "$_pg_d $_pg_t") || continue
			[ -n "$_pg_e" ] && [ "$_pg_e" -le "$release_cutoff" ] || continue
			_pg_ver=${_pg_ver%/</a>}
			printf '%s\n' "${_pg_ver#v}"
		done | sort -uV | tail -1)
	ts=$(latest_gh timescale/timescaledb 's/^v//')
	# pgvector publishes tags but no GitHub releases.
	vec=$(latest_tag pgvector/pgvector 'refs/tags/v*' \
		'^v[0-9]+\.[0-9]+\.[0-9]+$' 's/^v//')
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
	server=$(latest_tag valkey-io/valkey 'refs/tags/*' \
		'^[0-9]+\.[0-9]+\.[0-9]+$' 's/$//')
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
	ch_version=$(latest_tag ClickHouse/ClickHouse 'refs/tags/*-lts' \
		'^v[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-lts$' 's/^v//; s/-lts$//')
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
		 | select('"$jq_aged"')
		 | select([.assets[].name | select(test("-bin-(ubuntu-x64|ubuntu-arm64|macos-arm64)\\.tar\\.gz$"))]
			| unique | length == 3)
		 | .tag_name][0]')
fi
case "$llama_v" in b*) ;; *) llama_v="b$llama_v" ;; esac
decide llama-embedding "$llama_v"

# -------------------------------------------------------------------- mysql
# Repack of Oracle's "Linux - Generic" binaries for MySQL test lanes.
# Tracks mysql-server's 9.x git tags; the CDN tarball can lag the tag, so the
# newest tag clearing the bake-in window whose tarball is published wins.
mysql_v=$(git ls-remote --tags https://github.com/mysql/mysql-server 'refs/tags/mysql-9.*' |
	sed 's|.*refs/tags/mysql-||' | grep -E '^9\.[0-9]+\.[0-9]+$' | sort -uVr | head -15 |
	while IFS= read -r _m_v; do
		_m_e=$(tag_epoch mysql/mysql-server "mysql-$_m_v") || continue
		[ -n "$_m_e" ] && [ "$_m_e" -le "$release_cutoff" ] || continue
		curl -fsSI --retry 3 -o /dev/null --max-time 20 \
			"https://dev.mysql.com/get/Downloads/MySQL-${_m_v%.*}/mysql-${_m_v}-linux-glibc2.28-aarch64.tar.xz" \
			2>/dev/null || continue
		printf '%s\n' "$_m_v"
		break
	done)
decide mysql "$(force_or mysql "$mysql_v")"

# -------------------------------------------------------------------- k3s
# Node binaries + zstd airgap images, mirrored verbatim from k3s-io releases —
# fetched at every node boot, the same per-node-pull class as the oci mirrors.
# One run can build upstream latest plus every version pinned in stacks.txt.
# The matrix is emitted after the stack checks below.
k3s_v=$(force_or k3s "$(latest_gh k3s-io/k3s 's/^v//')")
k3s_candidates=$k3s_v
k3s_forced_v=
[ "$force_product" = k3s ] && k3s_forced_v=$k3s_v

# --------------------------------------------------------------- k3s-system
# Images listed by the k3s release itself: pause, coredns,
# local-path-provisioner, klipper-helm, and busybox. Each k3s version gets one
# release containing a zstd:chunked OCI asset per image.
k3s_system_v=$(force_or k3s-system "$k3s_v")
k3s_system_candidates=$k3s_system_v
k3s_system_forced_v=
[ "$force_product" = k3s-system ] && k3s_system_forced_v=$k3s_system_v

# ------------------------------------------------------------------ stacks
# stacks.txt declares the k3s and image versions used by each cloud. Rows from
# a stack are queued only when all of them already exist here or are available
# upstream. Build and publication failures are still handled by their jobs.
stacks_file="$script_dir/stacks.txt"
oci_file="$script_dir/oci-images.txt"
oci_stack_cells=
oci_cell_keys=

awk '
	/^[[:space:]]*(#|$)/ { next }
	NF != 3 {
		printf "check.sh: bad stacks.txt line %d: expected 3 fields\n", NR > "/dev/stderr"
		bad = 1
		next
	}
	$1 !~ /^[a-z0-9][a-z0-9-]*$/ ||
	$2 !~ /^(k3s|oci-[a-z0-9][a-z0-9-]*)$/ ||
	$3 !~ /^[a-zA-Z0-9_][a-zA-Z0-9_.+-]*$/ {
		printf "check.sh: bad stacks.txt line %d: %s %s %s\n", NR, $1, $2, $3 > "/dev/stderr"
		bad = 1
		next
	}
	{
		key = $1 SUBSEP $2
		if (seen[key]++) {
			printf "check.sh: duplicate stacks.txt product at line %d: %s %s\n", NR, $1, $2 > "/dev/stderr"
			bad = 1
		}
	}
	END { exit bad }
' "$stacks_file"

# Catch misspelled image products as configuration errors instead of holding
# the affected stack forever.
while read -r _s_stack _s_product _s_version; do
	case "$_s_stack" in '' | '#'*) continue ;; esac
	case "$_s_product" in
	k3s) ;;
	oci-*)
		_s_name=${_s_product#oci-}
		awk -v n="$_s_name" 'NF >= 4 && $1 == n { found = 1 } END { exit !found }' "$oci_file" || {
			echo "check.sh: $_s_product in stacks.txt is not listed in oci-images.txt" >&2
			exit 1
		} ;;
	esac
done <"$stacks_file"

stack_row_ok() { # <product> <tag> -> all required releases exist or can build
	sver=${2#v}
	case "$1" in
	k3s)
		upgrade_ver=$(printf '%s' "$sver" | tr '+' '-')
		if printf '%s\n' "$existing_tags" | grep -qxF "k3s/v$sver" &&
			printf '%s\n' "$existing_tags" | grep -qxF "k3s-system/v$sver" &&
			printf '%s\n' "$existing_tags" | grep -qxF "oci-k3s-upgrade/v$upgrade_ver"; then
			return 0
		fi
		gh api "repos/k3s-io/k3s/releases/tags/$2" >/dev/null 2>&1 &&
			skopeo inspect --raw --retry-times 3 \
				"docker://rancher/k3s-upgrade:$(printf '%s' "$2" | tr '+' '-')" \
				>/dev/null 2>&1 ;;
	oci-*)
		printf '%s\n' "$existing_tags" | grep -qxF "$1/v$sver" && return 0
		s_repo=$(awk -v n="${1#oci-}" 'NF>=4 && $1==n { print $2; exit }' "$oci_file")
		[ -n "$s_repo" ] &&
			skopeo inspect --raw --retry-times 3 \
				"docker://$s_repo:$2" >/dev/null 2>&1 ;;
	*) return 1 ;;
	esac
}

stacks=$(awk 'NF>=3 && $1!~/^#/ { print $1 }' "$stacks_file" | sort -u)
[ -n "$stacks" ] && ensure_cmds gh skopeo
for stack in $stacks; do
	held=
	while read -r s_p s_v; do
		stack_row_ok "$s_p" "$s_v" || held="$held $s_p=$s_v"
	done <<-STACKROWS
		$(awk -v s="$stack" 'NF>=3 && $1==s { print $2, $3 }' "$stacks_file")
	STACKROWS
	if [ -n "$held" ]; then
		echo "stack $stack held; unavailable:$held" >&2
		continue
	fi
	echo "stack $stack: all versions available"
	while read -r s_p s_v; do
		sver=${s_v#v}
		case "$s_p" in
		k3s)
			case " $k3s_candidates " in
			*" $sver "*) ;;
			*) k3s_candidates="$k3s_candidates $sver" ;;
			esac
			case " $k3s_system_candidates " in
			*" $sver "*) ;;
			*) k3s_system_candidates="$k3s_system_candidates $sver" ;;
			esac
			s_name=k3s-upgrade
			s_repo=docker.io/rancher/k3s-upgrade
			s_tag=$(printf '%s' "$s_v" | tr '+' '-')
			sver=$(printf '%s' "$sver" | tr '+' '-') ;;
		oci-*)
			s_name=${s_p#oci-}
			s_repo=$(awk -v n="$s_name" 'NF>=4 && $1==n { print $2; exit }' "$oci_file")
			s_tag=$s_v ;;
		*) continue ;;
		esac
		printf '%s\n' "$existing_tags" | grep -qxF "oci-$s_name/v$sver" && continue
		case " $oci_cell_keys " in
		*" $s_name:$sver "*) ;;
		*)
			oci_cell_keys="$oci_cell_keys $s_name:$sver"
			oci_stack_cells="${oci_stack_cells:+$oci_stack_cells,}$(printf \
				'{"name":"%s","ref":"%s","version":"%s"}' \
				"$s_name" "$s_repo:$s_tag" "$sver")" ;;
		esac
	done <<-STACKROWS
		$(awk -v s="$stack" 'NF>=3 && $1==s { print $2, $3 }' "$stacks_file")
	STACKROWS
done

# shellcheck disable=SC2086 # $k3s_candidates is a word list, split intended
k3s_matrix=$(ver_matrix k3s "$k3s_forced_v" $k3s_candidates)
k3s_build=false
[ -n "$k3s_matrix" ] && k3s_build=true
printf 'k3s_build=%s\nk3s_matrix={"include":[%s]}\n' "$k3s_build" "$k3s_matrix" >>"$out"

# One matrix cell per (version, image): the image set comes from each built
# version's own k3s-images.txt — verified against its GitHub asset digest —
# minus the components the deployment disables: traefik, metrics-server, klipper-lb.
# build-k3s-system runs one cell per image; release-k3s-system uses the
# version-only matrix to merge a version's cells into one release.
k3s_system_matrix=
k3s_system_images_matrix=
k3s_system_build=false
k3s_images_work=$(mktemp -d "${TMPDIR:-/tmp}/k3s-images.XXXXXX")
# shellcheck disable=SC2086 # $k3s_system_candidates is a word list, split intended
for ks_v in $k3s_system_candidates; do
	if [ "$ks_v" != "$k3s_system_forced_v" ] &&
		printf '%s\n' "$existing_tags" | grep -qxF "k3s-system/v$ks_v"; then
		echo "k3s-system: v$ks_v build=false"
		continue
	fi
	ks_digest=$(gh api "repos/k3s-io/k3s/releases/tags/v$ks_v" \
		--jq '.assets[] | select(.name == "k3s-images.txt") | .digest // empty' |
		sed 's/^sha256://')
	[ -n "$ks_digest" ] || {
		echo "check.sh: no GitHub asset digest for k3s-images.txt at v$ks_v" >&2
		exit 1
	}
	ks_file="$k3s_images_work/$ks_v.txt"
	fetch "https://github.com/k3s-io/k3s/releases/download/v$ks_v/k3s-images.txt" \
		"$ks_file" "$ks_digest"
	# grep exits 1 when the filter drops every line; keep set -e from turning
	# that into a silent exit so the empty-set diagnostic below can run.
	ks_images=$(grep -vE 'traefik|metrics-server|klipper-lb' "$ks_file") || true
	[ -n "$ks_images" ] || {
		echo "check.sh: k3s-images.txt at v$ks_v produced an empty image set" >&2
		exit 1
	}
	k3s_system_build=true
	k3s_system_matrix="${k3s_system_matrix:+$k3s_system_matrix,}{\"version\":\"$ks_v\"}"
	echo "k3s-system: v$ks_v build=true"
	while IFS= read -r ks_ref; do
		[ -n "$ks_ref" ] || continue
		ks_name=${ks_ref%:*}
		ks_name=${ks_name##*/}
		k3s_system_images_matrix="${k3s_system_images_matrix:+$k3s_system_images_matrix,}$(printf \
			'{"version":"%s","name":"%s","ref":"%s"}' \
			"$ks_v" "$ks_name" "$ks_ref")"
	done <<-KS_IMAGES
		$ks_images
	KS_IMAGES
done
rm -rf "$k3s_images_work"
printf 'k3s_system_build=%s\nk3s_system_matrix={"include":[%s]}\n' \
	"$k3s_system_build" "$k3s_system_matrix" >>"$out"
printf 'k3s_system_images_matrix={"include":[%s]}\n' \
	"$k3s_system_images_matrix" >>"$out"

# ------------------------------------------------------------------ flatcar
# Public release artifacts under <channel>.release.flatcar-linux.net, mirrored
# for pin durability — the CDN drops old versions while downstream pins keep
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
# The channel exposes only "current" — no history to fall back to — so a
# version.txt touched inside the bake-in window defers the product (and the
# sysext combo, which embeds the same version) to the next run.
flatcar_fresh=
if [ "$release_min_age" -gt 0 ]; then
	_lm=$(curl -fsSIL --retry 3 \
		"https://stable.release.flatcar-linux.net/amd64-usr/current/version.txt" |
		sed -n 's/^[Ll]ast-[Mm]odified:[[:space:]]*//p' | tail -1 | tr -d '\r')
	_lm_e=$(to_epoch "$_lm") || true
	{ [ -n "$_lm_e" ] && [ "$_lm_e" -le "$release_cutoff" ]; } || flatcar_fresh=true
fi
if [ -n "$flatcar_fresh" ]; then
	printf 'flatcar_version=%s\nflatcar_build=false\n' "$flatcar_v" >>"$out"
	echo "flatcar: $flatcar_v inside the 12h bake-in window — deferring"
else
	decide flatcar "$flatcar_v"
fi

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
if [ -n "$flatcar_fresh" ]; then
	printf 'flatcar_zfs_sysext_version=%s\nflatcar_zfs_sysext_build=false\n' \
		"${sysext_flatcar}-zfs${sysext_zfs}" >>"$out"
	echo "flatcar-zfs-sysext: flatcar $sysext_flatcar inside the 12h bake-in window — deferring"
else
	decide flatcar-zfs-sysext "${sysext_flatcar}-zfs${sysext_zfs}"
fi

# --------------------------------------------------------------- oci mirrors
# zstd:chunked repacks of upstream platform images. scripts/oci-images.txt
# lists "<name> <registry/repo> <gh repo|pin:tag> <sed>": the resolved tag is
# the upstream GitHub release tag transformed by <sed> ("-" or empty = no
# transform), or a literal pin:<tag> for chart-pinned images with no release
# source. Registry tag listings are unordered and paginated (ghcr caps
# tags/list at 100 per page), so they can't resolve latest — the GH release
# is the source of truth. A GitHub release can precede (or skip) registry
# promotion, so the newest release whose image is actually pushed wins; if
# nothing recent is servable the product is skipped until the next run. A
# missing pinned tag fails the run.
# Output is a build matrix (all arches are handled in one skopeo copy).
# Stack-declared pins from scripts/stacks.txt seed the matrix; the loop's
# latest-resolution cells skip any name:version a stack already queued.
oci_matrix=$oci_stack_cells
oci_names=
oci_build=false
[ -n "$oci_matrix" ] && oci_build=true
oci_matched_force=false
# Resolution probes the registry for every row, so skopeo is needed before
# the loop (the stacks section only ensures it when stacks.txt has rows).
ensure_cmds skopeo
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
	pinned=false
	if [ "$oci_name" = "$force_oci_name" ] && [ -n "$force_oci_tag" ]; then
		oci_tag=$force_oci_tag
	else
		case "$oci_gh" in
		pin:*)
			# Chart-pinned image or a registry with no release source: the
			# tag is literal, bumped by editing this file.
			oci_tag=${oci_gh#pin:}
			pinned=true ;;
		*)
			oci_tag=$(latest_eligible_oci "$oci_gh" "$oci_sed" "$oci_repo")
			[ -n "$oci_tag" ] || {
				if [ "$oci_name" = "$force_oci_name" ]; then
					echo "check.sh: no servable tag in recent $oci_gh releases" >&2
					exit 1
				fi
				echo "oci-$oci_name: no servable tag in recent $oci_gh releases — skipping"
				continue
			} ;;
		esac
	fi
	oci_ver="${oci_tag#v}"
	case " $oci_cell_keys " in
	*" $oci_name:$oci_ver "*)
		echo "oci-$oci_name: $oci_repo:$oci_tag already queued by a stack" ;;
	*)
		if [ "$forced" = true ] ||
			! printf '%s\n' "$existing_tags" | grep -qxF "oci-$oci_name/v$oci_ver"; then
			ensure_cmds skopeo
			if ! emit_oci "$oci_name" "$oci_repo:$oci_tag" "$oci_ver"; then
				if [ "$forced" = true ] || [ "$pinned" = true ]; then
					# A missing pinned tag is a configuration error.
					echo "check.sh: image not on registry: $oci_repo:$oci_tag" >&2
					exit 1
				fi
				echo "oci-$oci_name: $oci_repo:$oci_tag not on registry yet — skipping"
			fi
		else
			echo "oci-$oci_name: oci-$oci_name/v$oci_ver build=false"
		fi ;;
	esac
done <"$oci_file"
if [ -n "$force_oci_name" ] && [ "$oci_matched_force" = false ]; then
	echo "check.sh: '$force_oci_name' is not in oci-images.txt" >&2
	exit 1
fi
printf 'oci_build=%s\noci_matrix={"include":[%s]}\n' "$oci_build" "$oci_matrix" >>"$out"

# ----------------------------------------------------------------- ci tools
# Verified mirrors of small public binaries that consumers pin by
# sha256. ci-tools.txt lists
# "<name> <gh-repo> <x64-url> <arm64-url> <mode>"; latest is the repo's GitHub
# latest release (tool_latest() — nodejs/node resolves to the newest LTS line).
# Output is a build matrix, one cell per missing tool.
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
	[ -n "$tool_tag" ] || tool_tag=$(tool_latest "$tool_repo")
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

# ---------------------------------------------------------- pulumi plugins
# Pulumi resource provider binaries the deployments use, pinned in
# pulumi-plugins.txt (<name> <version> <gh-repo>). The manifest is the version
# source (like graalvm.txt), so there is no upstream resolution and no bake-in
# window: a bump is a manifest edit, and the next run builds the missing
# release. Output is a build matrix per (provider, platform) plus a release
# matrix per provider.
pulumi_plugins_file="$script_dir/pulumi-plugins.txt"
pulumi_plugins_platforms="linux-x64 linux-arm64 darwin-arm64"
pulumi_plugins_matrix=
pulumi_plugins_images_matrix=
pulumi_plugins_build=false
pulumi_plugins_names=
pulumi_plugins_matched_force=false
while read -r pp_name pp_ver pp_repo || [ -n "$pp_name" ]; do
	case "$pp_name" in '' | '#'*) continue ;; esac
	case " $pulumi_plugins_names " in
	*" $pp_name "*)
		echo "check.sh: duplicate name in pulumi-plugins.txt: $pp_name" >&2
		exit 1 ;;
	esac
	pulumi_plugins_names="$pulumi_plugins_names $pp_name"
	[ -n "$pp_ver" ] && [ -n "$pp_repo" ] || {
		echo "check.sh: bad pulumi-plugins.txt line: '$pp_name $pp_ver $pp_repo'" >&2
		exit 1
	}
	if [ "$pp_name" = "$force_pulumi_plugin" ]; then
		pulumi_plugins_matched_force=true
		[ -z "$force_version" ] || [ "$force_version" = "$pp_ver" ] || {
			echo "check.sh: pulumi plugin versions are pinned in pulumi-plugins.txt (currently $pp_ver) — update the manifest to bump" >&2
			exit 1
		}
	fi
	forced=false
	if [ "$pp_name" = "$force_pulumi_plugin" ] ||
		[ "$force_all_pulumi_plugins" = true ]; then
		forced=true
	fi
	if [ "$forced" = true ] ||
		! printf '%s\n' "$existing_tags" | grep -qxF "pulumi-plugin-$pp_name/v$pp_ver"; then
		pulumi_plugins_build=true
		pulumi_plugins_matrix="${pulumi_plugins_matrix:+$pulumi_plugins_matrix,}$(printf \
			'{"name":"%s","version":"%s","repo":"%s"}' \
			"$pp_name" "$pp_ver" "$pp_repo")"
		# shellcheck disable=SC2086 # $pulumi_plugins_platforms is a word list, split intended
		for pp_platform in $pulumi_plugins_platforms; do
			pulumi_plugins_images_matrix="${pulumi_plugins_images_matrix:+$pulumi_plugins_images_matrix,}$(printf \
				'{"name":"%s","version":"%s","platform":"%s"}' \
				"$pp_name" "$pp_ver" "$pp_platform")"
		done
		echo "pulumi-plugin-$pp_name: v$pp_ver build=true ($pulumi_plugins_platforms)"
	else
		echo "pulumi-plugin-$pp_name: pulumi-plugin-$pp_name/v$pp_ver build=false"
	fi
done <"$pulumi_plugins_file"
if [ -n "$force_pulumi_plugin" ] && [ "$pulumi_plugins_matched_force" = false ]; then
	echo "check.sh: '$force_pulumi_plugin' is not in pulumi-plugins.txt" >&2
	exit 1
fi
printf 'pulumi_plugins_build=%s\npulumi_plugins_matrix={"include":[%s]}\n' \
	"$pulumi_plugins_build" "$pulumi_plugins_matrix" >>"$out"
printf 'pulumi_plugins_images_matrix={"include":[%s]}\n' \
	"$pulumi_plugins_images_matrix" >>"$out"
