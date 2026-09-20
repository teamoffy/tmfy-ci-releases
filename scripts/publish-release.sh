#!/bin/sh
# Publish a release: assemble SHA256SUMS.txt from the packed assets, then
# create or update <tag>. Release notes are read from stdin.
# usage: publish-release.sh <tag> <title> <assets-dir>
# env: GH_TOKEN, GITHUB_REPOSITORY
set -eu
tag="${1:?usage: publish-release.sh <tag> <title> <assets-dir>}"
title="${2:?usage: publish-release.sh <tag> <title> <assets-dir>}"
assets="${3:?usage: publish-release.sh <tag> <title> <assets-dir>}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"

[ -d "$assets" ] || { echo "publish-release.sh: no assets dir $assets" >&2; exit 1; }

# Sidecars stay out of the release: upstream-* files carry provenance for the
# notes, per-file .sha256s are redundant next to SHA256SUMS.txt, and
# release-info.env is build plumbing.
rm -f "$assets"/upstream-* "$assets"/*.sha256 "$assets/release-info.env"

# SHA256SUMS.txt covers every file we ship — most products are tar.zst, but
# mirror products publish upstream files verbatim (k3s binaries, Flatcar
# images, sysext .raw). The case guard keeps SHA256SUMS.txt out of its own
# input: the redirect creates it before the ./* glob expands.
(
	cd "$assets" &&
		for f in ./*; do
			[ -f "$f" ] || continue
			case "$f" in ./SHA256SUMS.txt) continue ;; esac
			printf '%s  %s\n' "$(sha256_of "$f")" "${f#./}"
		done >SHA256SUMS.txt
)
[ -s "$assets/SHA256SUMS.txt" ] || {
	echo "publish-release.sh: no assets in $assets" >&2
	exit 1
}
notes=$(mktemp "${TMPDIR:-/tmp}/release-notes.XXXXXX")
trap 'rm -f "$notes"' EXIT INT TERM
cat >"$notes"

if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
	# Keep the release and tag in place. Deleting and recreating an older release
	# changes its creation order, which makes "latest asset" lookups pick it.
	gh release upload "$tag" --repo "$repo" --clobber "$assets"/*
	gh release edit "$tag" --repo "$repo" --title "$title" --notes-file "$notes"
else
	gh release create "$tag" --repo "$repo" \
		--title "$title" \
		--notes-file "$notes" \
		"$assets"/*
fi
