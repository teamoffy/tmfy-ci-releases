#!/bin/sh
# Mirror one upstream image as a zstd:chunked OCI image layout, packed into a
# tar.zst release asset. Only linux platforms are kept — windows variants carry
# multi-GB base layers no tea node can pull (gcp-pd-csi-driver: 4.4 GB total,
# 0.26 GB of it linux) and blow GitHub's 2 GiB asset cap. Every layer is
# re-encoded to zstd:chunked, which lets containers/storage clients use range
# requests and reuse chunks during partial pulls. Writes release-info.env
# (provenance for the notes) next to the asset.
# usage: oci-mirror.sh <name> <repo:tag>
# env:
#   OCI_WORK   work dir (default .oci-mirror-work)
set -eu
name="${1:?usage: oci-mirror.sh <name> <repo:tag>}"
ref="${2:?usage: oci-mirror.sh <name> <repo:tag>}"
work="${OCI_WORK:-$PWD/.oci-mirror-work}"
out="$work/out"

case "$name" in '' | *[!a-z0-9-]*)
	echo "oci-mirror.sh: invalid name '$name'" >&2
	exit 2 ;;
esac
case "$ref" in
*@*) echo "oci-mirror.sh: digest refs not supported: $ref" >&2; exit 2 ;;
esac
printf '%s\n' "$ref" | LC_ALL=C grep -Eq '^[^/]+/[a-z0-9_./-]+:[a-zA-Z0-9_][a-zA-Z0-9_.-]*$' || {
	echo "oci-mirror.sh: invalid tagged image: $ref" >&2
	exit 2
}
tag="${ref##*:}"
version="${tag#v}"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"
ensure_cmds skopeo jq zstd

rm -rf "$work"
mkdir -p "$out" "$work/stage"

# Digest of the upstream top-level manifest/index, for the release notes.
raw="$work/upstream-manifest.json"
skopeo inspect --raw "docker://$ref" >"$raw"
upstream_digest=$(sha256_of "$raw")

# Keep every linux/* platform the index ships, drop everything else (windows,
# darwin, attestations). Single-manifest images carry no platform list and
# copy as-is; an index with zero linux platforms is a bug worth failing on.
platforms=$(jq -r '[.manifests[]? | select(.platform.os == "linux") |
	"linux/" + .platform.architecture] | unique | join(",")' "$raw")
if [ -n "$platforms" ]; then
	# --strip-removed-platforms rewrites the inner index to only the copied
	# platforms — without it the index keeps dangling refs to windows
	# manifests that were never copied.
	set -- --multi-arch "$platforms" --strip-removed-platforms --remove-signatures
elif jq -e 'has("manifests")' "$raw" >/dev/null; then
	echo "oci-mirror.sh: $ref: image index has no linux platforms" >&2
	exit 1
else
	set -- --all
fi

# Re-encode to zstd:chunked inside an OCI layout. --dest-force-compress-format
# recompresses even already-zstd layers, so every layer carries the chunked
# TOC annotations.
entry="oci-$name-$version"
layout="$work/stage/$entry"
attempt=1
while :; do
	rm -rf "$layout"
	if skopeo copy "$@" --dest-compress-format zstd:chunked --dest-compress-level 19 \
		--dest-force-compress-format "docker://$ref" "oci:$layout:$tag"; then
		break
	fi
	[ "$attempt" -lt 3 ] || exit 1
	attempt=$((attempt + 1))
	echo "oci-mirror.sh: copy failed; retrying ($attempt/3)" >&2
	sleep 5
done

# Verify the layout: exactly one top-level manifest, and every image manifest
# below it has only chunked zstd layers. Non-image children (attestation
# manifests etc.) are copied verbatim and skipped.
jq -e '.manifests | length == 1' "$layout/index.json" >/dev/null
top_digest=$(jq -r '.manifests[0].digest' "$layout/index.json")
blob_path() { printf '%s/blobs/%s/%s\n' "$layout" "${1%%:*}" "${1#*:}"; }
check_manifest() {
	jq -e '
		if has("layers") then
			if .config.mediaType |
				(startswith("application/vnd.oci.image.config") or
				 startswith("application/vnd.docker.container.image"))
			then all(.layers[];
				.mediaType == "application/vnd.oci.image.layer.v1.tar+zstd"
				and .annotations["io.github.containers.zstd-chunked.manifest-checksum"] != null)
			else true end
		else true end' "$1" >/dev/null || {
		echo "oci-mirror.sh: ${1##*/} carries non-chunked image layers" >&2
		exit 1
	}
}
case "$(jq -r '.manifests[0].mediaType' "$layout/index.json")" in
*image.index* | *manifest.list*)
	# BuildKit adds unknown/unknown attestation children whose in-toto layers
	# are metadata, not container image layers, and are copied verbatim.
	jq -r '.manifests[] |
		select(.annotations["vnd.docker.reference.type"] != "attestation-manifest") |
		.digest' "$(blob_path "$top_digest")" | while IFS= read -r child; do
		check_manifest "$(blob_path "$child")"
	done ;;
*)
	check_manifest "$(blob_path "$top_digest")" ;;
esac
# --raw: a plain inspect resolves the host platform, which a Linux-only image
# index may not have (e.g. running this on macOS).
skopeo inspect --raw "oci:$layout:$tag" >/dev/null

# The layout's blobs are already zstd:chunked (verified above), so the outer
# archive compresses nothing meaningful — level 12 repacks multi-GB layouts in
# seconds where 22 took ~20 min, at identical asset size.
asset="$out/oci-$name-$version-oci.tar.zst"
sh "$script_dir/pack.sh" "$work/stage" "$asset" "$entry" 12
size=$(wc -c <"$asset" | tr -d ' ')
[ "$size" -lt 2000000000 ] || {
	echo "oci-mirror.sh: $asset is ${size}B — over GitHub's 2 GiB asset cap" >&2
	exit 1
}

cat >"$out/release-info.env" <<EOF
NAME=$name
REF=$ref
TAG=$tag
VERSION=$version
UPSTREAM_DIGEST=sha256:$upstream_digest
OCI_DIGEST=$top_digest
EOF
echo "mirrored $ref -> $asset (sha256:$upstream_digest -> $top_digest)"
