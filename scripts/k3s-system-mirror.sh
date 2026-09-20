#!/bin/sh
# Mirror the system images listed by a k3s release as zstd:chunked OCI layouts.
# They are published together under k3s-system/v<k3s-version>.
#
# The image list comes from the release's own k3s-images.txt (verified via its
# GitHub asset digest), excluding the components disabled by tea: traefik,
# metrics-server, and klipper-lb.
#
# usage: k3s-system-mirror.sh <k3s-version>   e.g. 1.37.0+k3s1
# env:
#   K3S_SYSTEM_WORK   work dir (default .k3s-system-work)
#   GH_TOKEN          required — the k3s-images.txt asset digest comes from
#                     the GitHub API
set -eu
version="${1:?usage: k3s-system-mirror.sh <k3s-version>}"
tag="v$version"
work="${K3S_SYSTEM_WORK:-$PWD/.k3s-system-work}"
out="$work/out"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"
ensure_cmds gh jq
[ -n "${GH_TOKEN:-}" ] || {
	echo "k3s-system-mirror.sh: GH_TOKEN is required (asset digest check)" >&2
	exit 2
}

rm -rf "$work"
mkdir -p "$out"

# k3s-images.txt is a release asset: verify it against its GitHub digest, the
# same check k3s-mirror.sh applies.
digest=$(gh api "repos/k3s-io/k3s/releases/tags/$tag" \
	--jq '.assets[] | select(.name == "k3s-images.txt") | .digest // empty' |
	sed 's/^sha256://')
[ -n "$digest" ] || {
	echo "k3s-system-mirror.sh: no GitHub asset digest for k3s-images.txt at $tag" >&2
	exit 1
}
fetch "https://github.com/k3s-io/k3s/releases/download/$tag/k3s-images.txt" \
	"$work/k3s-images.txt" "$digest"

# Drop the components disabled by tea (ServiceLB, Traefik, metrics-server).
grep -vE 'traefik|metrics-server|klipper-lb' "$work/k3s-images.txt" \
	>"$work/keep.txt"
[ -s "$work/keep.txt" ] || {
	echo "k3s-system-mirror.sh: k3s-images.txt at $tag produced an empty image set" >&2
	exit 1
}

count=0
while IFS= read -r ref; do
	[ -n "$ref" ] || continue
	# docker.io/rancher/mirrored-pause:3.10.2 -> mirrored-pause
	name=${ref%:*}
	name=${name##*/}
	OCI_WORK="$work/m-$name" sh "$script_dir/oci-mirror.sh" "$name" "$ref"
	mv "$work/m-$name"/out/oci-*.tar.zst "$out/"
	# The release job uses this provenance in its notes. publish-release.sh
	# removes the file before uploading the assets.
	mv "$work/m-$name/out/release-info.env" "$out/upstream-info-$name.env"
	count=$((count + 1))
done <"$work/keep.txt"

echo "mirrored $count k3s system images for $tag"
