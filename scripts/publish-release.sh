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
found=false
for f in "$assets"/*.tar.zst; do
	[ -f "$f" ] && found=true && break
done
[ "$found" = true ] || {
	echo "publish-release.sh: no .tar.zst assets in $assets" >&2
	exit 1
}

rm -f "$assets/upstream-sha256.txt" "$assets"/*.sha256
(
	cd "$assets" &&
		for f in ./*.tar.zst; do
			printf '%s  %s\n' "$(sha256_of "$f")" "${f#./}"
		done >SHA256SUMS.txt
)
notes=$(mktemp "${TMPDIR:-/tmp}/release-notes.XXXXXX.md")
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
