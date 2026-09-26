#!/bin/sh
# Repack Playwright's browser builds as an ms-playwright cache tree: run
# `playwright install --only-shell chromium webkit` on the native runner with
# PLAYWRIGHT_BROWSERS_PATH pointed at the work dir, so the archive carries the
# canonical layout and INSTALLATION_COMPLETE markers. Consumers extract into
# the cache parent (~/.cache on Linux) and `playwright install` then has
# nothing to download.
# usage: playwright-browsers-repack.sh <playwright-version>
# env:
#   PW_BROWSERS_WORK      work dir (default .pw-browsers-work)
#   PW_BROWSERS_PLATFORM  platform token override (default: host platform)
set -eu
version="${1:?usage: playwright-browsers-repack.sh <playwright-version>}"
work="${PW_BROWSERS_WORK:-$PWD/.pw-browsers-work}"
out="$work/out"
browsers="$work/ms-playwright"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"

platform="${PW_BROWSERS_PLATFORM:-}"
if [ -z "$platform" ]; then
	case "$(uname -s)-$(uname -m)" in
	Linux-x86_64) platform=linux-x64 ;;
	Linux-aarch64) platform=linux-arm64 ;;
	Darwin-arm64) platform=darwin-arm64 ;;
	*)
		echo "playwright-browsers-repack.sh: unsupported host $(uname -s)-$(uname -m)" >&2
		exit 2 ;;
	esac
fi

# npx ships with npm; no apt/brew package is named npx.
ensure_cmds npm zstd

rm -rf "$work"
mkdir -p "$out" "$browsers"

# playwright publishes no checksums for its CDN browser builds; the installer
# itself validates the archives and stamps INSTALLATION_COMPLETE. The packed
# tar.zst is what SHA256SUMS.txt pins downstream.
PLAYWRIGHT_BROWSERS_PATH="$browsers" \
	npx --yes "playwright@$version" install --only-shell chromium webkit

set -- "$browsers"/chromium_headless_shell-*
shell_dir=$1
set -- "$browsers"/webkit-*
webkit_dir=$1
for dir in "$shell_dir" "$webkit_dir"; do
	[ -d "$dir" ] && [ -f "$dir/INSTALLATION_COMPLETE" ] || {
		echo "playwright-browsers-repack.sh: $dir missing INSTALLATION_COMPLETE" >&2
		exit 1
	}
done
for headed in "$browsers"/chromium-[0-9]*/; do
	[ -e "$headed" ] || break
	echo "playwright-browsers-repack.sh: headed chromium installed ($headed); --only-shell must not ship it" >&2
	exit 1
done

# Smoke test: launch the headless shell the archive actually carries. Linux
# needs its system libs first — the same `chromium` dependency group
# playwright's --with-deps installs.
case "$platform" in
linux-*)
	PLAYWRIGHT_BROWSERS_PATH="$browsers" \
		npx --yes "playwright@$version" install-deps chromium >/dev/null ;;
darwin-*) ;;
*)
	echo "playwright-browsers-repack.sh: unsupported platform '$platform'" >&2
	exit 2 ;;
esac
# The shell unpacks into chrome-headless-shell-linux64 / -linux-arm64 /
# -mac-arm64 (playwright's own executable layout; linux x64 has no dash
# before the arch).
set -- "$shell_dir"/chrome-headless-shell-*/chrome-headless-shell
shell_exe=$1
[ -f "$shell_exe" ] || {
	echo "playwright-browsers-repack.sh: no headless shell binary under $shell_dir" >&2
	exit 1
}
"$shell_exe" --version
"$shell_exe" --version | grep -q "for Testing" || {
	echo "playwright-browsers-repack.sh: unexpected headless shell --version output" >&2
	exit 1
}

# .links records the builder's playwright package dir (the ephemeral npx cache
# path) and __dirlock an interrupted install's lock; neither is part of the
# browser trees, and the former would ship a machine-local path consumers
# cannot resolve.
rm -rf "$browsers/.links" "$browsers/__dirlock"

asset="$out/playwright-browsers-${version}-${platform}.tar.zst"
sh "$script_dir/pack.sh" "$work" "$asset" ms-playwright

verify="$work/verify"
verify_extract "$asset" "$verify"
[ -f "$verify/ms-playwright/$(basename -- "$shell_dir")/INSTALLATION_COMPLETE" ] &&
	[ -f "$verify/ms-playwright/$(basename -- "$webkit_dir")/INSTALLATION_COMPLETE" ] || {
	echo "playwright-browsers-repack.sh: repacked archive lost a browser marker" >&2
	exit 1
}
echo "mirrored $asset"
