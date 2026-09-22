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
#                   graalvm:  a JDK version on GDS  e.g. 25.0.4.1.1
#                   flatcar-zfs-sysext: flatcar/zfs  e.g. 4593.2.5/2.4.4
#                   oci-mirror: <name>:<tag>   e.g. cilium:v1.20.1
#                   oci-<name>: <tag>          e.g. product=oci-cilium
#                   ci-tools:   <name>:<tag>   e.g. kubectl:v1.36.4
#                   <tool name>: <tag>          e.g. product=kubectl
#                   (empty rebuilds every image/tool in the list at latest)
#                   pulumi-plugins:            product=pulumi-plugins
#                   pulumi-plugin-<name>:      product=pulumi-plugin-aws
#                   (empty = the provider's latest release; a version input
#                   builds that exact version)
#                   stacks:                    product=stacks (republish the
#                   resolved stacks release; takes no version)
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
force_stacks=false
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
	# Every provider rebuilds at latest; a version input is meaningless here.
	if [ -n "$force_version" ]; then
		echo "check.sh: product=pulumi-plugins rebuilds every provider in pulumi-plugins.txt at latest; use product=pulumi-plugin-<name> for one" >&2
		exit 1
	fi
	force_all_pulumi_plugins=true ;;
pulumi-plugin-*)
	# pulumi-plugin-<name> forces that provider; a version input builds that
	# exact upstream release.
	force_pulumi_plugin="${force_product#pulumi-plugin-}" ;;
stacks)
	# Force-republish the resolved stacks release.
	if [ -n "$force_version" ]; then
		echo "check.sh: product=stacks takes no version" >&2
		exit 1
	fi
	force_stacks=true ;;
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

# iso_epoch <ts> — epoch for ISO-8601 ("2026-09-21T22:07:22.000Z"), the GDS
# timeCreated format. Parsed as UTC on both date flavors.
iso_epoch() {
	_ie_d=$(printf '%s' "$1" | sed 's/\.[0-9]*//; s/Z$//; s/T/ /')
	TZ=UTC0 date -d "$_ie_d" +%s 2>/dev/null && return 0
	TZ=UTC0 date -j -f "%Y-%m-%d %H:%M:%S" "$_ie_d" +%s 2>/dev/null
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

# latest_release_matching <owner/repo> <tag-regex> <sed> — newest non-draft,
# non-prerelease release whose tag matches <tag-regex> and clears the bake-in
# window, transformed by <sed>. Empty when nothing matches; an API failure
# aborts the run (a transient failure must not read as "no version").
latest_release_matching() {
	_lrm_json=$(gh api "repos/$1/releases?per_page=100") || {
		echo "check.sh: failed to list releases for $1" >&2
		exit 1
	}
	printf '%s\n' "$_lrm_json" | jq -r '
		.[] | select((.draft | not) and (.prerelease | not) and .published_at)
		| select('"$jq_aged"')
		| .tag_name' | grep -E "$2" | sort -Vr | head -1 | sed "$3"
}

# registry_latest <registry/repo> <tag-regex> — newest tag on the registry
# matching the regex, version-sorted. Version order, not push order: registry
# listings are unordered and paginated.
registry_latest() {
	ensure_cmds skopeo jq
	skopeo list-tags "docker://$1" 2>/dev/null |
		jq -r '.Tags[]' | grep -E "$2" | sort -Vr | head -1
}

# cilium_envoy_tag <cilium-release-tag> — the cilium-envoy image tag cilium's
# chart pins at that release (values.yaml). The `chart:cilium` source uses it
# so the envoy mirror always matches the mirrored cilium.
cilium_envoy_tag() {
	curl -fsSL --retry 3 --max-time 30 \
		"https://raw.githubusercontent.com/cilium/cilium/$1/install/kubernetes/cilium/values.yaml" |
		sed -n '/repository: "quay.io\/cilium\/cilium-envoy"/{n; s/.*tag: *"\([^"]*\)".*/\1/p; q;}'
}

# cilium_for_minor <minor> — newest cilium release whose documented
# e2e-tested Kubernetes set includes <minor> (the compatibility.rst grid at
# the release tag). Cilium runs on every node, so a release that does not
# list the cloud's minor is a break risk: no match steps the cloud down a
# minor. One patch per minor line is checked, newest first.
cilium_for_minor() {
	_cf_minor=$1
	_cf_json=$(gh api "repos/cilium/cilium/releases?per_page=100") || {
		echo "check.sh: failed to list cilium releases" >&2
		exit 1
	}
	for _cf_tag in $(printf '%s\n' "$_cf_json" | jq -r '
		.[] | select((.draft | not) and (.prerelease | not) and .published_at)
		| select('"$jq_aged"')
		| .tag_name' | sort -Vr | awk -F. '!seen[$1 "." $2]++'); do
		_cf_supported="$oci_work/cilium-supported-$_cf_tag"
		if [ ! -f "$_cf_supported" ]; then
			curl -fsSL --retry 3 --max-time 30 \
				-o "$oci_work/cilium-compatibility.rst" \
				"https://raw.githubusercontent.com/cilium/cilium/$_cf_tag/Documentation/network/kubernetes/compatibility.rst" || {
				echo "check.sh: cannot read the cilium $_cf_tag compatibility table" >&2
				exit 1
			}
			awk -F'|' 'NF >= 4 && $2 ~ /[0-9]+\.[0-9]+/ {
				gsub(/[ \t]/, "", $2); print $2; exit }' \
				"$oci_work/cilium-compatibility.rst" >"$_cf_supported"
		fi
		if tr ',' '\n' <"$_cf_supported" | grep -qx "$_cf_minor"; then
			printf '%s\n' "$_cf_tag"
			return 0
		fi
	done
	return 0
}

# minor_num/prev_minor/short_minor — k8s minor arithmetic: comparable number,
# the previous minor, and the k8s minor without the leading "1." (1.36 -> 36).
minor_num() { printf '%s\n' "$((${1%%.*} * 100 + ${1#*.}))"; }
prev_minor() { printf '%s\n' "${1%%.*}.$((${1#*.} - 1))"; }
short_minor() { printf '%s\n' "${1#1.}"; }
esc_dots() { printf '%s' "$1" | sed 's/\./\\./g'; }

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
# Oracle GraalVM for JDK, resolved from the GDS artifact API — the same
# endpoint setup-graalvm queries, so "latest" is real. Items carry the
# artifact id, its sha256 (checksum), and timeCreated; the JDK version itself
# only exists in the artifact filename, resolved via a HEAD on the content
# URL. The newest JDK version published for all three platforms (and outside
# the bake-in window) wins — a staged platform rollout falls back to the
# newest version they share. A forced version is a JDK version GDS still
# publishes for every platform.
ensure_cmds curl jq
gds_base=https://gds.oracle.com/api/20220101/artifacts
gds_query='productId=D53FAE8052773FFAE0530F15000AA6C6&metadata=edition:ee&metadata=isBase:True&status=PUBLISHED&responseFields=id&responseFields=checksum&responseFields=metadata&responseFields=timeCreated&displayName=Oracle%20GraalVM&sortBy=timeCreated&sortOrder=DESC&limit=15'
gds_jdk_version() { # <artifact-id> -> JDK version inside the artifact filename
	curl -fsSI --retry 3 --max-time 30 "$gds_base/$1/content" |
	sed -n 's|.*graalvm-jdk-||; s|_[a-z0-9]*-[a-z0-9]*_bin\.tar\.gz.*||p' |
	sed 's/.*-//'
}
graalvm_candidates() { # <os> <arch> -> "jdkver id sha" rows, newest first
	curl -fsSL --retry 3 --max-time 60 "$gds_base?$gds_query&metadata=os:$1&metadata=arch:$2" |
	jq -r '.items[] | [.id, .checksum, .timeCreated // ""] | @tsv' |
	while read -r _g_id _g_sha _g_tc; do
		_g_e=$(iso_epoch "$_g_tc") || continue
		[ -n "$_g_e" ] && [ "$_g_e" -le "$release_cutoff" ] || continue
		_g_v=$(gds_jdk_version "$_g_id") || continue
		# GDS lists some gated artifacts whose /content 401s — skip them.
		[ -n "$_g_v" ] || continue
		printf '%s %s %s\n' "$_g_v" "$_g_id" "$_g_sha"
	done | awk '!seen[$1]++'
}
glx=$(graalvm_candidates linux amd64)
gar=$(graalvm_candidates linux aarch64)
gma=$(graalvm_candidates macos aarch64)
if [ "$force_product" = graalvm ] && [ -n "$force_version" ]; then
	graalvm_v=$force_version
	for _g_list in "$glx" "$gar" "$gma"; do
		printf '%s\n' "$_g_list" | awk -v v="$graalvm_v" '$1==v{f=1} END{exit !f}' || {
			echo "check.sh: GDS has no $graalvm_v artifact for all platforms" >&2
			exit 1
		}
	done
else
	graalvm_v=$(printf '%s\n' "$glx" | cut -d' ' -f1 | sort -uVr |
		while read -r _g_v; do
			# shellcheck disable=SC2015 # || continue is the intended either-failed path
			printf '%s\n' "$gar" | cut -d' ' -f1 | grep -qx "$_g_v" &&
				printf '%s\n' "$gma" | cut -d' ' -f1 | grep -qx "$_g_v" || continue
			printf '%s\n' "$_g_v"
			break
		done)
fi
[ -n "$graalvm_v" ] || {
	echo "check.sh: no GraalVM version on GDS for all platforms" >&2
	exit 1
}
_g_row() { awk -v v="$graalvm_v" '$1==v{print $2, $3; exit}'; }
glx_row=$(printf '%s\n' "$glx" | _g_row)
gar_row=$(printf '%s\n' "$gar" | _g_row)
gma_row=$(printf '%s\n' "$gma" | _g_row)
graalvm_artifacts=$(jq -nc \
	--arg i1 "${glx_row%% *}" --arg s1 "${glx_row##* }" \
	--arg i2 "${gar_row%% *}" --arg s2 "${gar_row##* }" \
	--arg i3 "${gma_row%% *}" --arg s3 "${gma_row##* }" \
	'{"linux-x64":{id:$i1,sha:$s1},"linux-arm64":{id:$i2,sha:$s2},"darwin-arm64":{id:$i3,sha:$s3}}')
printf 'graalvm_artifacts=%s\n' "$graalvm_artifacts" >>"$out"
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
# Tracks the latest LTS line: Oracle's apt repo names its LTS components
# mysql-<line>-lts, so the highest is the current LTS series (9.7 today;
# 8.4 is the older LTS, the rest of 9.x is Innovation). Within the line, the
# newest tag clearing the bake-in window whose generic tarball is published
# wins — the CDN tarball can lag the git tag.
mysql_lts=$(curl -fsSL --retry 3 https://repo.mysql.com/apt/ubuntu/dists/noble/Release |
	grep -oE 'mysql-[0-9]+\.[0-9]+-lts' | sed 's/^mysql-//; s/-lts$//' | sort -uVr | head -1)
[ -n "$mysql_lts" ] || {
	echo "check.sh: no mysql-*-lts component in the upstream apt repo" >&2
	exit 1
}
mysql_v=$(git ls-remote --tags https://github.com/mysql/mysql-server "refs/tags/mysql-${mysql_lts}.*" |
	sed 's|.*refs/tags/mysql-||' | grep -E "^${mysql_lts}\.[0-9]+$" | sort -uVr | head -15 |
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
# stacks.txt declares each cloud's target Kubernetes version (a minor, or
# `latest` for the newest minor k3s publishes); the deployed set (k3s plus
# every in-scope oci-images.txt component) is computed from each row's source
# and <k8s> rule, never pinned. A component that cannot supply the target
# minor (e.g. no cloud-CCM image for it yet) drops the whole cloud one minor
# and resolution retries, so a cloud never runs ahead of its slowest
# dependency. Resolved sets seed the build matrices below and are published
# as a content-addressed stacks release for consumers.
stacks_file="$script_dir/stacks.txt"
oci_file="$script_dir/oci-images.txt"
oci_work=$(mktemp -d "${TMPDIR:-/tmp}/oci-rows.XXXXXX")
oci_matrix=
oci_cell_keys=
oci_build=false
stacks_floor=30 # lowest k8s minor the resolver considers (1.30)
stacks_base=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
stacks_dir="${stacks_base%/}/stacks-resolved"
stacks_out="$stacks_dir/stacks.txt"

awk '
	/^[[:space:]]*(#|$)/ { next }
	NF != 3 {
		printf "check.sh: bad stacks.txt line %d: expected <stack> k8s <minor>\n", NR > "/dev/stderr"
		bad = 1
		next
	}
	$1 !~ /^[a-z0-9][a-z0-9-]*$/ || $2 != "k8s" || $3 !~ /^([0-9]+\.[0-9]+|latest)$/ {
		printf "check.sh: bad stacks.txt line %d: %s %s %s\n", NR, $1, $2, $3 > "/dev/stderr"
		bad = 1
		next
	}
	{
		key = $1 SUBSEP $2
		if (seen[key]++) {
			printf "check.sh: duplicate stacks.txt declaration at line %d: %s\n", NR, $1 > "/dev/stderr"
			bad = 1
		}
	}
	END { exit bad }
' "$stacks_file"

# The component list the resolver works from: oci-images.txt rows. Registry
# regexes carry no whitespace, so a plain read recovers the fields.
awk '
	/^[[:space:]]*(#|$)/ { next }
	NF != 6 {
		printf "check.sh: bad oci-images.txt line %d: expected 6 fields\n", NR > "/dev/stderr"
		bad = 1
		next
	}
	{
		if (seen[$1]++) {
			printf "check.sh: duplicate oci-images.txt name at line %d: %s\n", NR, $1 > "/dev/stderr"
			bad = 1
		}
		print $1, $2, $3, $4, $5, $6
	}
	END { exit bad }
' "$oci_file" >"$oci_work/rows" || exit 1

# oci_resolve <registry-repo> <source> <sed> — newest image tag a row's
# source can offer (empty when nothing is servable).
oci_resolve() {
	case "$2" in
	pin:*) printf '%s\n' "${2#pin:}" ;;
	registry:*) registry_latest "$1" "${2#registry:}" ;;
	chart:cilium)
		_or_cilium=$(oci_latest_tag cilium)
		[ -n "$_or_cilium" ] || return 0
		_or_tag=$_or_cilium
		case "$_or_tag" in v*) ;; *) _or_tag="v$_or_tag" ;; esac
		cilium_envoy_tag "$_or_tag" ;;
	*)
		_or_sed=$3
		case "$_or_sed" in '' | -) _or_sed='s/$//' ;; esac
		latest_eligible_oci "$2" "$_or_sed" "$1" ;;
	esac
}

# oci_latest_tag <name> — memoized oci_resolve for one oci-images.txt row.
oci_latest_tag() {
	_ol_name=$1
	_ol_file="$oci_work/latest-$_ol_name"
	if [ -f "$_ol_file" ]; then
		cat "$_ol_file"
		return 0
	fi
	# shellcheck disable=SC2046 # the row is space-separated fields
	set -- $(awk -v n="$_ol_name" '$1 == n { print $2, $3, $4; exit }' "$oci_work/rows")
	[ -n "${1:-}" ] || {
		echo "check.sh: '$_ol_name' is not in oci-images.txt" >&2
		exit 1
	}
	_ol_tag=$(oci_resolve "$1" "$2" "$3")
	printf '%s\n' "$_ol_tag" >"$_ol_file"
	printf '%s\n' "$_ol_tag"
}

# stack_minor_tag <registry-repo> <source> <sed> <rule> <minor> — newest tag
# for a k8s-minor-coupled component (empty when the rule has nothing for the
# minor, which steps the cloud down one minor).
stack_minor_tag() {
	case "$4" in
	minor) _sm_re="^v$(esc_dots "$5")\\.[0-9]+$" ;;
	minor-trail1) # dash cannot nest $() two levels deep in one string
		_sm_prev=$(esc_dots "$(prev_minor "$5")")
		_sm_re="^v($(esc_dots "$5")|$_sm_prev)\\.[0-9]+$" ;;
	minor-short) _sm_re="^v$(short_minor "$5")\\.[0-9]+(\\.[0-9]+)+$" ;;
	*) return 1 ;;
	esac
	case "$2" in
	registry:*) registry_latest "$1" "$_sm_re" ;;
	pin:*) printf '%s\n' "${2#pin:}" ;;
	*)
		_sm_sed=$3
		case "$_sm_sed" in '' | -) _sm_sed='s/$//' ;; esac
		latest_release_matching "$2" "$_sm_re" "$_sm_sed" ;;
	esac
}

# resolve_cloud <stack> <target-minor> — newest minor at or below <target>
# where k3s and every component resolves. Prints "k3s <version>" plus one
# "<name> <tag>" row per oci component on success; returns 1 when nothing
# resolves.
resolve_cloud() {
	_rs_file="$oci_work/resolved-$1"
	_rs_minor=$2
	while [ "$(minor_num "$_rs_minor")" -ge "$stacks_floor" ]; do
		_rs_ok=true
		_rs_k3s=$(latest_release_matching k3s-io/k3s \
			"^v$(esc_dots "$_rs_minor")\.[0-9]+\+k3s[0-9]+$" 's/^v//')
		[ -n "$_rs_k3s" ] || _rs_ok=false
		: >"$_rs_file"
		if [ "$_rs_ok" = true ]; then
			while read -r _rs_name _rs_repo _rs_src _rs_sed _rs_rule _rs_scope; do
				case "$_rs_scope" in
				shared | "$1") ;;
				*) continue ;;
				esac
				case "$_rs_rule" in
				any) _rs_tag=$(oci_latest_tag "$_rs_name") ;;
				cilium) _rs_tag=$(cilium_for_minor "$_rs_minor") ;;
				same:* | chart:*)
					_rs_ref=$(awk -v n="${_rs_rule#*:}" '$1 == n { print $2; exit }' "$_rs_file")
					[ -n "$_rs_ref" ] || {
						_rs_ok=false
						break
					}
					case "$_rs_rule" in
					same:*) _rs_tag=$_rs_ref ;;
					*) _rs_tag=$(cilium_envoy_tag "v${_rs_ref#v}") ;;
					esac ;;
				*) _rs_tag=$(stack_minor_tag "$_rs_repo" "$_rs_src" "$_rs_sed" "$_rs_rule" "$_rs_minor") ;;
				esac
				[ -n "$_rs_tag" ] || {
					_rs_ok=false
					break
				}
				printf '%s %s\n' "$_rs_name" "$_rs_tag" >>"$_rs_file"
			done <"$oci_work/rows"
		fi
		if [ "$_rs_ok" = true ]; then
			printf 'k3s %s\n' "$_rs_k3s"
			cat "$_rs_file"
			return 0
		fi
		_rs_minor=$(prev_minor "$_rs_minor")
	done
	return 1
}

stacks=$(awk 'NF >= 3 && $1 !~ /^#/ { print $1 }' "$stacks_file" | sort -u)
[ -n "$stacks" ] && ensure_cmds gh jq curl skopeo

# A component's scope must be "shared" or one of the declared clouds; its
# k8s rule must be known; same:/chart: references must name a component
# listed above (rows resolve in file order, so operators/envoy follow their
# cilium). Catch these as configuration errors instead of holding a cloud.
: >"$oci_work/components"
while read -r _sc_name _sc_repo _sc_src _sc_sed _sc_rule _sc_scope; do
	case "$_sc_scope" in
	shared) ;;
	*)
		printf '%s\n' "$stacks" | grep -qx "$_sc_scope" || {
			echo "check.sh: oci-images.txt: $_sc_name has unknown scope '$_sc_scope'" >&2
			exit 1
		} ;;
	esac
	case "$_sc_rule" in
	any | cilium | minor | minor-short | minor-trail1) ;;
	same:* | chart:*)
		_sc_ref=${_sc_rule#*:}
		grep -qx "$_sc_ref" "$oci_work/components" || {
			echo "check.sh: oci-images.txt: $_sc_name: $_sc_rule must reference a component listed above it" >&2
			exit 1
		}
		case "$_sc_rule" in
		chart:*) [ "$_sc_ref" = cilium ] || {
			echo "check.sh: oci-images.txt: $_sc_name: only chart:cilium is supported" >&2
			exit 1
		} ;;
		esac ;;
	*)
		echo "check.sh: oci-images.txt: $_sc_name has unknown k8s rule '$_sc_rule'" >&2
		exit 1 ;;
	esac
	printf '%s\n' "$_sc_name" >>"$oci_work/components"
done <"$oci_work/rows"

mkdir -p "$stacks_dir"
{
	printf '# Resolved cloud stacks — generated by check.sh from the stacks.txt\n'
	printf '# declarations and oci-images.txt rules; do not edit.\n'
	printf '#\n#   <stack> <product> <version-or-tag>\n'
} >"$stacks_out"
stacks_published=false
for stack in $stacks; do
	target=$(awk -v s="$stack" '$1 == s { print $3; exit }' "$stacks_file")
	if [ "$target" = latest ]; then
		# Newest k3s minor: the resolver steps down from there per component.
		target=$(latest_gh k3s-io/k3s 's/^v//')
		target=$(printf '%s' "$target" | sed 's/+.*//; s/\.[0-9]*$//')
		[ -n "$target" ] || {
			echo "check.sh: stack $stack: cannot resolve the newest k3s minor" >&2
			exit 1
		}
	fi
	if ! rows=$(resolve_cloud "$stack" "$target"); then
		echo "check.sh: stack $stack: no k8s minor down to 1.$stacks_floor resolves (target $target)" >&2
		continue
	fi
	k3s_ver=$(printf '%s\n' "$rows" | awk '$1 == "k3s" { print $2 }')
	effective=$(printf '%s' "$k3s_ver" | sed 's/+.*//')
	# Queue the resolved set; a component whose upstream artifact is not
	# servable yet keeps its cell for a later run instead of failing.
	pending=
	while read -r s_name s_tag; do
		[ "$s_name" = k3s ] && continue
		s_repo=$(awk -v n="$s_name" '$1 == n { print $2; exit }' "$oci_work/rows")
		s_ver=${s_tag#v}
		printf '%s\n' "$existing_tags" | grep -qxF "oci-$s_name/v$s_ver" && continue
		emit_oci "$s_name" "$s_repo:$s_tag" "$s_ver" || pending="$pending $s_name=$s_tag"
	done <<-RESOLVED
		$(printf '%s\n' "$rows" | grep -v '^k3s ')
	RESOLVED
	# k3s carries k3s-system and the oci-k3s-upgrade image at the same version.
	case " $k3s_candidates " in
	*" $k3s_ver "*) ;;
	*) k3s_candidates="$k3s_candidates $k3s_ver" ;;
	esac
	case " $k3s_system_candidates " in
	*" $k3s_ver "*) ;;
	*) k3s_system_candidates="$k3s_system_candidates $k3s_ver" ;;
	esac
	k3s_upgrade_tag="v$(printf '%s' "$k3s_ver" | tr '+' '-')"
	k3s_upgrade_ver=${k3s_upgrade_tag#v}
	if ! printf '%s\n' "$existing_tags" | grep -qxF "oci-k3s-upgrade/v$k3s_upgrade_ver"; then
		emit_oci k3s-upgrade "docker.io/rancher/k3s-upgrade:$k3s_upgrade_tag" "$k3s_upgrade_ver" ||
			pending="$pending k3s-upgrade=$k3s_upgrade_tag"
	fi
	if [ -n "$pending" ]; then
		echo "check.sh: stack $stack: k8s $effective (target $target), awaiting:$pending" >&2
		continue
	fi
	echo "stack $stack: k8s $effective (target $target)"
	printf '%s\n' "$rows" | while read -r s_name s_tag; do
		case "$s_name" in
		k3s) printf '%s k3s v%s\n' "$stack" "$s_tag" ;;
		*) printf '%s oci-%s %s\n' "$stack" "$s_name" "$s_tag" ;;
		esac
	done >>"$stacks_out"
	stacks_published=true
done

if [ "$stacks_published" = true ]; then
	stacks_tag="stacks/v$(sha256_of "$stacks_out" | cut -c1-12)"
	if [ "$force_stacks" = true ] ||
		! printf '%s\n' "$existing_tags" | grep -qxF "$stacks_tag"; then
		stacks_build=true
	else
		stacks_build=false
	fi
else
	stacks_tag=
	stacks_build=false
fi
echo "stacks: ${stacks_tag:-no resolved cloud sets} build=$stacks_build"
printf 'stacks_build=%s\nstacks_tag=%s\nstacks_file=%s\n' \
	"$stacks_build" "$stacks_tag" "$stacks_out" >>"$out"

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
# lists "<name> <registry/repo> <source> <sed> <k8s> <scope>"; a row resolves
# to its source's newest servable image tag (see the file header for the
# source kinds). Registry tag listings are unordered and paginated (ghcr caps
# tags/list at 100 per page), so they can't resolve latest; GitHub releases
# and the version-sorted registry filter are the sources of truth, and the
# newest candidate whose image is actually pushed wins. If nothing recent is
# servable the product is skipped until the next run; a missing pin fails.
# Output is a build matrix (all arches are handled in one skopeo copy), with
# the resolved stack cells from scripts/stacks.txt seeded ahead of it; the
# loop skips any name:version a stack already queued.
oci_names=
oci_matched_force=false
# Resolution probes the registry for every row, so skopeo is needed before
# the loop (the stacks section only ensures it when stacks.txt has rows).
ensure_cmds skopeo
while read -r oci_name oci_repo oci_src oci_sed oci_rule oci_scope || [ -n "$oci_name" ]; do
	case "$oci_name" in '' | '#'*) continue ;; esac
	case " $oci_names " in
	*" $oci_name "*)
		echo "check.sh: duplicate name in oci-images.txt: $oci_name" >&2
		exit 1 ;;
	esac
	oci_names="$oci_names $oci_name"
	[ -n "$oci_repo" ] && [ -n "$oci_src" ] || {
		echo "check.sh: bad oci-images.txt line: '$oci_name $oci_repo $oci_src $oci_sed $oci_rule $oci_scope'" >&2
		exit 1
	}
	forced=false
	if [ "$oci_name" = "$force_oci_name" ]; then
		forced=true
		oci_matched_force=true
	elif [ "$force_product" = oci-mirror ] && [ -z "$force_oci_name" ]; then
		forced=true
	fi
	pinned=false
	case "$oci_src" in pin:*) pinned=true ;; esac
	if [ "$oci_name" = "$force_oci_name" ] && [ -n "$force_oci_tag" ]; then
		oci_tag=$force_oci_tag
	else
		# oci_latest_tag memoizes the resolution the stack resolver also used.
		oci_tag=$(oci_latest_tag "$oci_name")
		[ -n "$oci_tag" ] || {
			if [ "$oci_name" = "$force_oci_name" ]; then
				echo "check.sh: no servable tag for $oci_name ($oci_src)" >&2
				exit 1
			fi
			echo "oci-$oci_name: no servable tag ($oci_src) — skipping"
			continue
		}
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
done <"$oci_work/rows"
if [ -n "$force_oci_name" ] && [ "$oci_matched_force" = false ]; then
	echo "check.sh: '$force_oci_name' is not in oci-images.txt" >&2
	exit 1
fi
printf 'oci_build=%s\noci_matrix={"include":[%s]}\n' "$oci_build" "$oci_matrix" >>"$out"
rm -rf "$oci_work"

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
# Pulumi resource provider binaries the deployments use: one row per provider
# in pulumi-plugins.txt (<name> <gh-repo>), tracked at the repo's latest
# GitHub release. Output is a build matrix per (provider, platform) plus a
# release matrix per provider.
pulumi_plugins_file="$script_dir/pulumi-plugins.txt"
pulumi_plugins_platforms="linux-x64 linux-arm64 darwin-arm64"
pulumi_plugins_matrix=
pulumi_plugins_images_matrix=
pulumi_plugins_build=false
pulumi_plugins_names=
pulumi_plugins_matched_force=false
while read -r pp_name pp_repo || [ -n "$pp_name" ]; do
	case "$pp_name" in '' | '#'*) continue ;; esac
	case " $pulumi_plugins_names " in
	*" $pp_name "*)
		echo "check.sh: duplicate name in pulumi-plugins.txt: $pp_name" >&2
		exit 1 ;;
	esac
	pulumi_plugins_names="$pulumi_plugins_names $pp_name"
	[ -n "$pp_repo" ] || {
		echo "check.sh: bad pulumi-plugins.txt line: '$pp_name $pp_repo'" >&2
		exit 1
	}
	forced=false
	pp_ver=
	if [ "$pp_name" = "$force_pulumi_plugin" ]; then
		pulumi_plugins_matched_force=true
		forced=true
		if [ -n "$force_version" ]; then
			pp_ver=${force_version#v}
			gh api "repos/$pp_repo/releases/tags/v$pp_ver" >/dev/null 2>&1 || {
				echo "check.sh: no upstream release $pp_repo v$pp_ver" >&2
				exit 1
			}
		fi
	elif [ "$force_all_pulumi_plugins" = true ]; then
		forced=true
	fi
	[ -n "$pp_ver" ] || pp_ver=$(latest_gh "$pp_repo" 's/^v//')
	[ -n "$pp_ver" ] || {
		echo "check.sh: failed to resolve a version for pulumi-plugin-$pp_name" >&2
		exit 1
	}
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
