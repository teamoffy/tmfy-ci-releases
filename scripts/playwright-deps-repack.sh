#!/bin/sh
# Capture the apt package set `playwright install-deps chromium webkit`
# installs on an ubuntu runner as a tar.zst of the downloaded .deb files.
# Consumers on the same ubuntu release `dpkg -i` the bundle — no apt index or
# archive traffic at all.
#
# usage: playwright-deps-repack.sh <playwright-version>
# env:
#   PW_DEPS_WORK      work dir (default .pw-deps-work)
#   PW_DEPS_PLATFORM  platform token override (default ubuntu-<VERSION_ID>-<arch>)
set -eu
version="${1:?usage: playwright-deps-repack.sh <playwright-version>}"
work="${PW_DEPS_WORK:-$PWD/.pw-deps-work}"
out="$work/out"
debs="$work/debs"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"

require_linux playwright-deps-repack.sh "playwright's deb set is linux-only"
case "$(uname -m)" in
x86_64) arch=x64 ;;
aarch64) arch=arm64 ;;
*) echo "playwright-deps-repack.sh: unsupported arch $(uname -m)" >&2; exit 2 ;;
esac
# The bundle is only valid for the ubuntu release it was captured on — package
# names (e.g. libasound2 vs libasound2t64) and versions differ across releases.
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = ubuntu ] || {
	echo "playwright-deps-repack.sh: needs an ubuntu host (got ${ID:-?})" >&2
	exit 2
}
platform="${PW_DEPS_PLATFORM:-ubuntu-${VERSION_ID}-${arch}}"

ensure_cmds npm zstd

rm -rf "$work"
mkdir -p "$out" "$debs/partial"

# Redirect apt's download cache into the work dir, then run the real installer:
# the captured .deb set is exactly the package closure apt resolved for this
# image, transitive deps included.
printf 'Dir::Cache::archives "%s";\nAPT::Keep-Downloaded-Packages "true";\n' "$debs" |
	sudo tee /etc/apt/apt.conf.d/99pw-deps-capture >/dev/null
trap 'sudo rm -f /etc/apt/apt.conf.d/99pw-deps-capture' EXIT
npx --yes "playwright@$version" install-deps chromium webkit
sudo rm -f /etc/apt/apt.conf.d/99pw-deps-capture
trap - EXIT

# apt keeps its lock file and a partial/ dir (owned by its download sandbox
# user) in the archives dir; stage just the debs the install resolved.
stage="$work/stage"
mkdir -p "$stage/debs"
set -- "$debs"/*.deb
[ -f "$1" ] || {
	echo "playwright-deps-repack.sh: install-deps downloaded no debs" >&2
	exit 1
}
mv "$@" "$stage/debs/"
count=$#

asset="$out/playwright-deps-${version}-${platform}.tar.zst"
sh "$script_dir/pack.sh" "$stage" "$asset" debs

# Verify the archive survives a fresh extract and every member is a real deb.
verify="$work/verify"
verify_extract "$asset" "$verify"
[ "$(find "$verify/debs" -name '*.deb' | wc -l)" -eq "$count" ] || {
	echo "playwright-deps-repack.sh: repacked archive lost debs" >&2
	exit 1
}
for deb in "$verify"/debs/*.deb; do
	dpkg-deb --field "$deb" Package >/dev/null
done

echo "mirrored $asset ($count debs)"
