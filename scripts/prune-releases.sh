#!/bin/sh
# Prune releases beyond the newest KEEP_RELEASES per product.
# usage: prune-releases.sh
# env: GH_TOKEN, GITHUB_REPOSITORY, KEEP_RELEASES (default 15)
set -eu
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
keep="${KEEP_RELEASES:-15}"
products='aws-lc bun zlib-ng postgres valkey clickhouse pebble typesense zstd libgit2'

# Guard the arithmetic below: keep=0 (or junk) would prune every release.
case "$keep" in
'' | *[!0-9]*) echo "prune-releases.sh: KEEP_RELEASES must be a positive integer, got '$keep'" >&2; exit 1 ;;
0) echo "prune-releases.sh: KEEP_RELEASES must be at least 1" >&2; exit 1 ;;
esac

listing=$(mktemp "${TMPDIR:-/tmp}/releases.XXXXXX.txt")
trap 'rm -f "$listing"' EXIT INT TERM
gh api "repos/$repo/releases" --paginate --jq '.[].tag_name' >"$listing"

for prefix in $products; do
	grep "^$prefix/" "$listing" | tail -n +$((keep + 1)) | while IFS= read -r tag; do
		[ -n "$tag" ] || continue
		echo "deleting $tag"
		gh release delete "$tag" --repo "$repo" --yes --cleanup-tag ||
			echo "prune-releases.sh: failed to delete $tag" >&2
	done
done
