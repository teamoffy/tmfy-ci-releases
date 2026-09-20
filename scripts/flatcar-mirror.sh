#!/bin/sh
# Mirror one Flatcar release artifact, byte-verbatim, verified against the
# published .DIGESTS sidecar (sha512). Pin durability is the point: the channel
# CDN drops old versions, while tea's pins (image imports, sysext inputs) keep
# referencing them. Verbatim bytes keep the upstream sha512 valid.
#
# The artifact set — which (arch, file) pairs upstream publishes — is the
# build-flatcar matrix in release.yml; one matrix cell per artifact.
#
# usage: flatcar-mirror.sh <version> <arch> <upstream-file> <kind>
#        e.g. flatcar-mirror.sh 4757.2.0 amd64 flatcar_production_gce.tar.gz gce
# env:
#   FLATCAR_WORK    work dir (default .flatcar-work)
#   FLATCAR_CHANNEL release channel (default stable)
set -eu
version="${1:?usage: flatcar-mirror.sh <version> <arch> <upstream-file> <kind>}"
arch="${2:?usage: flatcar-mirror.sh <version> <arch> <upstream-file> <kind>}"
artifact="${3:?usage: flatcar-mirror.sh <version> <arch> <upstream-file> <kind>}"
kind="${4:?usage: flatcar-mirror.sh <version> <arch> <upstream-file> <kind>}"
channel="${FLATCAR_CHANNEL:-stable}"
work="${FLATCAR_WORK:-$PWD/.flatcar-work}"
out="$work/out"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"

rm -rf "$work"
mkdir -p "$out"

base="https://${channel}.release.flatcar-linux.net/${arch}-usr/${version}"
asset="flatcar-${kind}-${version}-${arch}.${artifact#*.}"
echo "==> $artifact ($arch) -> $asset"
fetch_flatcar "$base/$artifact" "$out/$asset"

echo "mirrored $asset"
