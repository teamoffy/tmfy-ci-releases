#!/bin/sh
# Repack one Chrome-for-Testing `chrome` build as a tar.zst rooted at
# chrome-for-testing/<version>/<platform>/ — the layout a managed-browser
# runtime expects under its cache root — so consumers can seed their cache
# without hitting googleapis.
# usage: chrome-for-testing-repack.sh <cft-version>
# env:
#   CFT_WORK      work dir (default .cft-work)
#   CFT_PLATFORM  platform token override (default: host platform)
# exit 3 means upstream publishes no build for this platform at this version —
# the caller treats it as a skipped matrix leg, not a failure.
set -eu
version="${1:?usage: chrome-for-testing-repack.sh <cft-version>}"
work="${CFT_WORK:-$PWD/.cft-work}"
out="$work/out"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"

platform="${CFT_PLATFORM:-}"
if [ -z "$platform" ]; then
	case "$(uname -s)-$(uname -m)" in
	Linux-x86_64) platform=linux-x64 ;;
	Linux-aarch64) platform=linux-arm64 ;;
	Darwin-arm64) platform=darwin-arm64 ;;
	*)
		echo "chrome-for-testing-repack.sh: unsupported host $(uname -s)-$(uname -m)" >&2
		exit 2 ;;
	esac
fi
case "$platform" in
linux-x64) upstream=linux64 ;;
linux-arm64) upstream=linux-arm64 ;;
darwin-arm64) upstream=mac-arm64 ;;
*)
	echo "chrome-for-testing-repack.sh: unsupported platform $platform" >&2
	exit 2 ;;
esac
case "$platform" in
linux-*) exe_rel="chrome-$upstream/chrome" ;;
darwin-*) exe_rel="chrome-$upstream/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" ;;
esac

ensure_cmds curl unzip zstd

rm -rf "$work"
mkdir -p "$out" "$work/dl" "$work/tree"

url="https://storage.googleapis.com/chrome-for-testing-public/$version/$upstream/chrome-$upstream.zip"
zip="$work/dl/chrome-$upstream.zip"
# Upstream publishes no index of which platforms a version shipped, so probe
# the object: 404 means the platform was never built at this version (skip the
# leg), while any other failure is a real download error — treating it as
# missing would silently thin the release's platform set.
http_code=$(curl -sSL --retry 3 -o "$zip" -w '%{http_code}' "$url") || {
	echo "chrome-for-testing-repack.sh: download failed: $url" >&2
	exit 1
}
case "$http_code" in
200) ;;
404)
	rm -f "$zip"
	echo "chrome-for-testing-repack.sh: no upstream chrome-$upstream build at $version" >&2
	exit 3 ;;
*)
	echo "chrome-for-testing-repack.sh: unexpected HTTP $http_code for $url" >&2
	exit 1 ;;
esac

# Upstream publishes no checksums; the packed asset plus the release's
# SHA256SUMS.txt are what the consumer's compiled-in executable digest
# re-verifies after extraction.
unzip -q "$zip" -d "$work/tree"
# The tree carries the upstream platform token (linux64/mac-arm64/linux-arm64):
# consumers resolve <cache>/chrome-for-testing/<ver>/<upstream-platform>/.
stage="$work/tree/chrome-for-testing/$version/$upstream"
mkdir -p "$stage"
mv "$work/tree/chrome-$upstream" "$stage/chrome-$upstream"
archive_sha=$(sha256_of "$zip")
exe="$stage/$exe_rel"
exe_sha=$(sha256_of "$exe")

# Smoke test: launch the binary the archive actually carries. Runner images
# ship Chrome's shared-library closure, so --version runs without extra deps.
"$exe" --version
"$exe" --version | grep -qi "for testing" || {
	echo "chrome-for-testing-repack.sh: unexpected --version output" >&2
	exit 1
}

asset="$out/chrome-for-testing-${version}-${platform}.tar.zst"
sh "$script_dir/pack.sh" "$work/tree" "$asset" chrome-for-testing

cat >"$out/release-info.env" <<EOF
UPSTREAM_URL=$url
ARCHIVE_SHA256=$archive_sha
EXECUTABLE_SHA256=$exe_sha
EOF

verify="$work/verify"
verify_extract "$asset" "$verify"
[ -f "$verify/chrome-for-testing/$version/$upstream/$exe_rel" ] || {
	echo "chrome-for-testing-repack.sh: repacked archive lost the executable" >&2
	exit 1
}
echo "mirrored $asset (executable sha256 $exe_sha)"
