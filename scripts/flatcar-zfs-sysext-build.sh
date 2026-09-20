#!/bin/sh
# Build OpenZFS as a systemd-sysext image for one exact Flatcar release.
# Ported from tea's build-flatcar-zfs-sysext.sh; downloads go through lib.sh.
#
# Flatcar ships an immutable /usr, no package manager, and no ZFS module. The
# only supported way to add an out-of-tree kernel module is a sysext: a
# squashfs image dropped into /etc/extensions and merged over /usr at boot.
#
# The build MUST happen against the kernel of the target Flatcar release, so
# it runs inside that release's own developer container (which carries the
# matching kernel sources at /lib/modules/<kver>/build). Building against
# anything else produces a module the target kernel refuses to load.
#
# The resulting image carries an extension-release file matching the image
# name and naming that exact Flatcar VERSION_ID. systemd-sysext refuses to
# merge an image whose name or VERSION_ID does not match, which prevents a
# module built for one kernel from being loaded on another.
#
# usage: flatcar-zfs-sysext-build.sh <flatcar-version> <zfs-version>
# env:
#   FLATCAR_ZFS_PLATFORM  linux-x64 | linux-arm64 (default: the host arch)
#   FLATCAR_ZFS_WORK      work dir (default .flatcar-zfs-work)
#   FLATCAR_CHANNEL       release channel (default stable)
#   GH_TOKEN              enables GitHub asset-digest verification of the zfs
#                         source tarball (the build fails without it)
set -eu
flatcar_v="${1:?usage: flatcar-zfs-sysext-build.sh <flatcar-version> <zfs-version>}"
zfs_v="${2:?usage: flatcar-zfs-sysext-build.sh <flatcar-version> <zfs-version>}"
channel="${FLATCAR_CHANNEL:-stable}"
work="${FLATCAR_ZFS_WORK:-$PWD/.flatcar-zfs-work}"
out="$work/out"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"
require_linux "$0" "kernel modules build only on Linux"
[ -n "${GH_TOKEN:-}" ] || {
	echo "$0: GH_TOKEN must be set — the zfs tarball is verified via its release asset digest" >&2
	exit 1
}
ensure_cmds gh

case "${FLATCAR_ZFS_PLATFORM:-}" in
"" | linux-x64) arch=amd64 ;;
linux-arm64) arch=arm64 ;;
*)
	echo "$0: unsupported FLATCAR_ZFS_PLATFORM '${FLATCAR_ZFS_PLATFORM}'" >&2
	exit 2 ;;
esac
case "$(uname -m)" in
x86_64) host_arch=amd64 ;;
aarch64) host_arch=arm64 ;;
*)
	echo "$0: unsupported host arch $(uname -m)" >&2
	exit 2 ;;
esac
[ "$arch" = "$host_arch" ] || {
	echo "$0: refusing to cross-build a kernel module: $arch on $host_arch" >&2
	exit 2
}
flatcar_arch="${arch}-usr"
case "$arch" in amd64) sysext_arch=x86-64 ;; *) sysext_arch=arm64 ;; esac

# Host packages; cmd and apt names differ, so map explicitly.
need_pkgs=
command -v systemd-nspawn >/dev/null 2>&1 || need_pkgs="$need_pkgs systemd-container"
command -v mksquashfs >/dev/null 2>&1 || need_pkgs="$need_pkgs squashfs-tools"
command -v depmod >/dev/null 2>&1 || need_pkgs="$need_pkgs kmod"
command -v bunzip2 >/dev/null 2>&1 || need_pkgs="$need_pkgs bzip2"
command -v unsquashfs >/dev/null 2>&1 || need_pkgs="$need_pkgs squashfs-tools"
if [ -n "$need_pkgs" ]; then
	sudo apt-get update
	# shellcheck disable=SC2086
	sudo apt-get install -y --no-install-recommends $need_pkgs
fi

# nspawn leaves root-owned files behind; a leftover work dir needs sudo.
sudo rm -rf "$work"
mkdir -p "$out"
export UPSTREAM_SHA_LOG="$work/upstream-sha256.txt"
: >"$UPSTREAM_SHA_LOG"

zfs_url="https://github.com/openzfs/zfs/releases/download/zfs-${zfs_v}/zfs-${zfs_v}.tar.gz"
zfs_asset="zfs-${zfs_v}.tar.gz"
zfs_sha=$(gh api "repos/openzfs/zfs/releases/tags/zfs-${zfs_v}" \
	--jq ".assets[] | select(.name == \"$zfs_asset\") | .digest // empty" |
	sed 's/^sha256://')
[ -n "$zfs_sha" ] || {
	echo "$0: no GitHub asset digest for $zfs_asset" >&2
	exit 1
}
fetch "$zfs_url" "$work/zfs.tar.gz" "$zfs_sha"

release_url="https://${channel}.release.flatcar-linux.net/${flatcar_arch}/${flatcar_v}"
echo "==> downloading the ${flatcar_v} developer container (${flatcar_arch})"
fetch_flatcar "$release_url/flatcar_developer_container.bin.bz2" \
	"$work/dev.bin.bz2"

echo "==> extracting"
bunzip2 -q "$work/dev.bin.bz2"

# The inner script runs as root inside the developer container. It resolves the
# kernel version from the container's own module tree rather than being told,
# so the module and the extension-release can never disagree about it.
cat >"$work/build-inner.sh" <<'INNER'
#!/bin/sh
set -eu
ZFS_VERSION="${ZFS_VERSION:?}"

set -- /lib/modules/*
KVER="${1##*/}"
[ -n "$KVER" ] || { echo "no kernel modules tree in the developer container" >&2; exit 1; }
[ -d "/lib/modules/${KVER}/build" ] || {
  echo "no kernel build tree at /lib/modules/${KVER}/build" >&2
  exit 1
}
echo "==> building OpenZFS ${ZFS_VERSION} against kernel ${KVER}"

cd /tmp
tar -xzf /mnt/work/zfs.tar.gz
cd "zfs-${ZFS_VERSION}"

# --prefix=/usr because a sysext may only add to /usr and /opt; anything the
# build wants to put in /etc or /var would simply not be merged at runtime.
./configure \
  --prefix=/usr \
  --libdir=/usr/lib64 \
  --sysconfdir=/etc \
  --with-linux="/lib/modules/${KVER}/build" \
  --with-linux-obj="/lib/modules/${KVER}/build" \
  --with-config=all \
  --disable-systemd \
  --disable-pyzfs \
  --enable-linux-builtin=no
make -j"$(nproc)"
make install DESTDIR=/tmp/stage

# Trim to what a node needs: the modules, the userland binaries, and the udev
# rules that give the pool stable device links. Headers, man pages, and the
# development libraries would triple the image for no runtime benefit.
STAGE=/tmp/stage
rm -rf "${STAGE}/usr/include" "${STAGE}/usr/share/man" "${STAGE}/usr/share/zfs" \
  "${STAGE}/usr/lib64/pkgconfig" "${STAGE}/usr/src" "${STAGE}/etc"
find "${STAGE}" -name '*.la' -delete
find "${STAGE}" -name '*.a' -delete

# `make install` puts the modules under /lib/modules, which on Flatcar is a
# symlink into /usr/lib/modules. A sysext image is merged at /usr, so the paths
# inside it must be the real /usr ones.
if [ -d "${STAGE}/lib/modules" ]; then
  mkdir -p "${STAGE}/usr/lib"
  cp -a "${STAGE}/lib/modules/." "${STAGE}/usr/lib/modules/"
  rm -rf "${STAGE}/lib"
fi
[ -f "${STAGE}/usr/lib/modules/${KVER}/extra/zfs.ko" ] \
  || [ -f "${STAGE}/usr/lib/modules/${KVER}/extra/zfs/zfs.ko" ] \
  || { echo "zfs.ko was not produced under /usr/lib/modules/${KVER}/extra" >&2; exit 1; }

echo "$KVER" > /tmp/kver
INNER
chmod +x "$work/build-inner.sh"

echo "==> building inside the developer container"
sudo systemd-nspawn \
	--quiet \
	--image="$work/dev.bin" \
	--bind="$work:/mnt/work" \
	--setenv=ZFS_VERSION="$zfs_v" \
	--resolv-conf=copy-host \
	/bin/sh -c '/mnt/work/build-inner.sh && cp -a /tmp/stage /mnt/work/stage && cp /tmp/kver /mnt/work/kver'

kver="$(cat "$work/kver")"
echo "==> assembling the sysext for kernel ${kver}"

tree="$work/tree"
image_name="zfs-${zfs_v}-${flatcar_v}-${sysext_arch}"
release_file="extension-release.${image_name}"
sudo mkdir -p "$tree"
sudo cp -a "$work/stage/usr" "$tree/usr"

# The merge gate. `ID` and `VERSION_ID` must equal the running OS's
# /etc/os-release values or systemd-sysext refuses the image; ARCHITECTURE
# stops a wrong-arch image from merging on a mixed-arch cluster.
sudo mkdir -p "$tree/usr/lib/extension-release.d"
sudo tee "$tree/usr/lib/extension-release.d/$release_file" >/dev/null <<EOF
ID=flatcar
VERSION_ID=${flatcar_v}
ARCHITECTURE=${sysext_arch}
EXTENSION_RELOAD_MANAGER=1
EOF

# depmod so `modprobe zfs` resolves the dependency chain (spl -> zfs) from the
# merged tree instead of failing on a missing modules.dep.
sudo depmod -b "$tree/usr" "$kver"
[ -s "$tree/usr/lib/modules/$kver/modules.dep" ] || {
	echo "depmod did not produce modules.dep" >&2
	exit 1
}

raw="$out/${image_name}.raw"
rm -f "$raw"
sudo mksquashfs "$tree" "$raw" -all-root -noappend -comp zstd -quiet
sudo chown "$(id -u):$(id -g)" "$raw"

# Smoke check: the merge gate inside the image must name the target release.
probe="$work/probe"
unsquashfs -d "$probe" "$raw" usr/lib/extension-release.d >/dev/null
grep -q "^VERSION_ID=${flatcar_v}\$" \
	"$probe/usr/lib/extension-release.d/$release_file" || {
	echo "$0: extension-release VERSION_ID does not match ${flatcar_v}" >&2
	exit 1
}

digest=$(sha256_of "$raw")
# Both architecture artifacts are merged into one release job. Keep the input
# logs arch-qualified so download-artifact does not silently overwrite one.
mv "$UPSTREAM_SHA_LOG" "$out/upstream-sha256-${sysext_arch}.txt"
echo "==> done"
echo "raw=$raw"
echo "sha256=$digest"
echo "kernel=$kver"
