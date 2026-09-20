#!/bin/sh
# Mirror a k3s release: the node binaries, the zstd airgap image tarballs, and
# the release metadata, verbatim. k3s is fetched by every node boot, so this is
# the same per-node-pull class as the oci-* image mirrors.
#
# Verification: the binaries and airgap tarballs are checked against upstream's
# own sha256sum-<arch>.txt, and every release asset is additionally checked
# against the sha256 digest GitHub records for it. install.sh is not a release
# asset — it is fetched from the tag's git tree and its sha256 is only
# recorded (nothing upstream to verify it against).
#
# usage: k3s-mirror.sh <version>          e.g. 1.37.0+k3s1 (upstream tag v…)
# env:
#   K3S_WORK   work dir (default .k3s-work)
#   GH_TOKEN   required — the asset digests come from the GitHub API
set -eu
version="${1:?usage: k3s-mirror.sh <version>}"
tag="v$version"
work="${K3S_WORK:-$PWD/.k3s-work}"
out="$work/out"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"
ensure_cmds gh jq
[ -n "${GH_TOKEN:-}" ] || {
	echo "k3s-mirror.sh: GH_TOKEN is required (asset digests come from the GitHub API)" >&2
	exit 2
}

rm -rf "$work"
mkdir -p "$out" "$work/dl"

base="https://github.com/k3s-io/k3s/releases/download/$tag"

# The release's own checksum manifests, then the GitHub asset digests. The
# binaries and airgap tarballs must pass both checks.
fetch "$base/sha256sum-amd64.txt" "$work/dl/sha256sum-amd64.txt"
fetch "$base/sha256sum-arm64.txt" "$work/dl/sha256sum-arm64.txt"

gh api "repos/k3s-io/k3s/releases/tags/$tag" >"$work/release.json"
gh_digest() { # <asset-name> -> sha256 or empty
	jq -r --arg asset "$1" \
		'.assets[] | select(.name == $asset) | .digest // empty' "$work/release.json" |
		sed 's/^sha256://'
}
expected() { # <file> <arch> -> upstream sha256
	sum=$(awk -v n="$1" '$2 == n { print $1 }' "$work/dl/sha256sum-$2.txt")
	digest=$(gh_digest "$1")
	if [ -n "$sum" ] && [ -n "$digest" ] && [ "$sum" != "$digest" ]; then
		echo "k3s-mirror.sh: upstream sources disagree on $1 ($sum vs $digest)" >&2
		exit 1
	fi
	if [ -z "$sum" ] && [ -z "$digest" ]; then
		echo "k3s-mirror.sh: no upstream checksum for $1" >&2
		exit 1
	fi
	printf '%s\n' "${sum:-$digest}"
}

for spec in "k3s amd64" "k3s-arm64 arm64" \
	"k3s-airgap-images-amd64.tar.zst amd64" \
	"k3s-airgap-images-arm64.tar.zst arm64" \
	"k3s-images.txt amd64"; do
	# shellcheck disable=SC2086 # word-splitting intended
	set -- $spec
	fetch "$base/$1" "$out/$1" "$(expected "$1" "$2")"
done

# install.sh ships in the git tree, not as a release asset — record but do not
# claim upstream verification.
fetch "https://raw.githubusercontent.com/k3s-io/k3s/$tag/install.sh" \
	"$out/install.sh"

echo "mirrored k3s $tag"
