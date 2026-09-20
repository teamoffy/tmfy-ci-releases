#!/bin/sh
# Mirror the Flatcar release artifacts tea consumes, byte-verbatim, verified
# against upstream's .DIGESTS (sha512) sidecars. Pin durability is the point:
# the channel CDN drops old versions, while tea's pins (image imports, sysext
# inputs) keep referencing them. Verbatim bytes keep the upstream sha512 valid.
#
# usage: flatcar-mirror.sh <version>      e.g. 4593.2.5
# env:
#   FLATCAR_WORK    work dir (default .flatcar-work)
#   FLATCAR_CHANNEL release channel (default stable)
#   FLATCAR_ARCHES  space-separated arches (default "amd64 arm64")
set -eu
version="${1:?usage: flatcar-mirror.sh <version>}"
channel="${FLATCAR_CHANNEL:-stable}"
arches="${FLATCAR_ARCHES:-amd64 arm64}"
work="${FLATCAR_WORK:-$PWD/.flatcar-work}"
out="$work/out"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"

rm -rf "$work"
mkdir -p "$out"

# <arch> <upstream filename> <asset kind> — the kind becomes part of the asset
# name. GCE is amd64-only: Flatcar publishes no arm64 GCE image.
artifacts="
amd64 flatcar_production_openstack_image.img.bz2 openstack
amd64 flatcar_production_gce.tar.gz gce
amd64 flatcar_developer_container.bin.bz2 dev-container
arm64 flatcar_production_openstack_image.img.bz2 openstack
arm64 flatcar_developer_container.bin.bz2 dev-container
"

printf '%s\n' "$artifacts" | while read -r artifact_arch artifact kind; do
	[ -n "$artifact_arch" ] || continue
	case " $arches " in
	*" $artifact_arch "*) ;;
	*) continue ;;
	esac
	base="https://${channel}.release.flatcar-linux.net/${artifact_arch}-usr/${version}"
	asset="flatcar-${kind}-${version}-${artifact_arch}.${artifact#*.}"
	echo "==> $artifact ($artifact_arch) -> $asset"
	fetch_flatcar "$base/$artifact" "$out/$asset"
done

echo "mirrored flatcar $version ($channel) for: $arches"
