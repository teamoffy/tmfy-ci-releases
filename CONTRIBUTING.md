# Contributing

## Pipeline

One workflow ([`release.yml`](.github/workflows/release.yml)), one daily run
(06:17 UTC), 36 jobs:

1. **check** — resolves every product's target version from upstream (GitHub
   releases where they exist, git tags or index listings where they don't, and
   the Flatcar channel's `version.txt`) and decides whether that version is
   already released here. For the `oci-*` image mirrors it also probes each
   resolved tag on its registry, and for both `oci-*` and the `ci-tools.txt`
   tools it emits a dynamic build matrix of what's missing.
2. **build-\<product\>** — one parallel job per product with its own platform
   matrix. `fail-fast: false` lets the other targets finish if one target fails.
   Every product is smoke-tested before publishing: compiled-and-run for the
   libraries, a live server boot for the services, checksum-verified repacks
   for the mirrors, layer-format verification for the OCI repacks.
3. **release-\<product\>** — assembles `SHA256SUMS.txt` and publishes the
   release with notes (upstream URLs/checksums, build recipe, license).
4. **cleanup** — prunes each product's releases beyond the newest
   `KEEP_RELEASES` (15) so fallback versions survive if automation stalls;
   set to `1` for strictly latest-only.

## Force-rebuilding a version

Dispatch `release.yml` with `product` set — that product always rebuilds and
replaces its release assets and notes in place, while the rest get their normal
daily check.
`version` is optional (upstream latest if empty); multi-component products
take slash-joined versions: postgres `18.6/2.29.2/0.8.6/1.1.1`, valkey
`9.1.2/1.0.1`, libgit2 `1.9.7/1.11.1`, flatcar-zfs-sysext `4593.2.5/2.4.4`.
`oci-mirror` takes `<name>:<tag>` from
[`oci-images.txt`](scripts/oci-images.txt) (e.g. `cilium:v1.20.1`), or force a
single image directly with `product=oci-<name>` + `version=<tag>`; an empty
version rebuilds the whole image list at latest. `ci-tools` works the same
way over [`ci-tools.txt`](scripts/ci-tools.txt) — `product=ci-tools` +
`version=<name>:<tag>` or `product=<tool name>` + `version=<tag>`. From the
Actions tab, or:

```sh
gh workflow run release.yml -f product=zstd -f version=1.5.7
gh workflow run release.yml -f product=oci-mirror -f version=cilium:v1.20.1
gh workflow run release.yml -f product=oci-cilium -f version=v1.20.1
gh workflow run release.yml -f product=flatcar-zfs-sysext -f version=4593.2.5/2.4.4
gh workflow run release.yml -f product=kubectl -f version=v1.36.4
```

PostgreSQL is pinned to 18.x — major bumps need a new VectorChord `.deb`
target, so bump them deliberately via a forced version.

## Scripts

- `check.sh` — version resolution for all products. Reads `FORCE_PRODUCT` /
  `FORCE_VERSION`, writes `<product>_version` / `<product>_build` lines to
  `GITHUB_OUTPUT` (plus `oci_matrix`/`oci_build` for the image mirrors and
  `tools_matrix`/`tools_build` for the ci-tools set).
- `oci-images.txt` — tracked image mirrors: `<name> <registry/repo> <gh repo>
  <sed>`, one per line. `<gh repo>`'s latest release tag, transformed by
  `<sed>`, is the image tag to mirror.
- `oci-mirror.sh <name> <repo:tag>` — `skopeo copy --all` re-encode of one
  upstream image to a zstd:chunked OCI layout, layer-format verification, then
  `pack.sh` to a `-oci.tar.zst` asset plus a `release-info.env` provenance
  file. Takes an `OCI_WORK` work dir.
- `k3s-mirror.sh <version>` — verbatim mirror of the k3s node binaries, zstd
  airgap tarballs, `k3s-images.txt`, and `install.sh`; binaries/airgap are
  verified against upstream `sha256sum-<arch>.txt` and everything else against
  GitHub asset digests. Takes `K3S_WORK` and `GH_TOKEN`.
- `flatcar-mirror.sh <version>` — verbatim mirror of the openstack/GCE/
  developer-container artifacts, verified against the upstream `.DIGESTS`
  sha512 sidecars. All kinds for `amd64`; `arm64` skips GCE (upstream ships
  no arm64 GCE image). Takes `FLATCAR_WORK`, `FLATCAR_CHANNEL` (default
  `stable`), `FLATCAR_ARCHES`.
- `flatcar-zfs-sysext-build.sh <flatcar> <zfs>` — OpenZFS compiled against the
  target Flatcar kernel inside that release's developer container
  (`systemd-nspawn`), packed as a squashfs `.raw` sysext with the
  `VERSION_ID=<flatcar>` merge gate. Same-arch only. Takes
  `FLATCAR_ZFS_PLATFORM`, `FLATCAR_ZFS_WORK`, `FLATCAR_CHANNEL`, `GH_TOKEN`.
- `ci-tools.txt` — tracked tools: `<name> <gh-repo> <x64-url> <arm64-url>
  <mode>` per line. `{tag}`/`{ver}` expand in the URLs; `mode` is `bin` (bare
  binary), `tarbin:<member>` (one binary out of an archive), or `tardir`
  (whole archive to `opt/<name>`).
- `tool-repack.sh <name> <tag>` — fetch + verify + repack one ci-tools.txt row
  into `linux-x64`/`linux-arm64` tar.zst assets plus `release-info.env`.
  GitHub-hosted assets verify via the asset digest; other hosts via the
  `.sha256`/`.sha256sum` sidecar. Takes `CI_TOOLS_WORK`, `GH_TOKEN`.
- `<product>-build.sh <version>...` — build, smoke-test, and pack one product.
  The mirrors use `*-repack.sh` instead (`bun-repack.sh`, `sqlite-vec-repack.sh`,
  `llama-embedding-repack.sh`): they verify upstream checksums where published
  and re-archive rather than compile. sqlite-vec and llama-embedding repack on
  each target's native runner so their smoke tests (loading `vec0`, running
  `llama-cli`) exercise the packaged binaries. Multi-component products take
  one arg per component (postgres 4, valkey 2, libgit2 2). Each
  takes a `*_PLATFORM` env (e.g. `linux-x64`) and a `*_WORK` work dir.
- `pack.sh <dir> <out.tar.zst> <entry>` — max-compressed tar.zst + sha256
  sidecar.
- `publish-release.sh <tag> <title> <assets-dir>` — SHA256SUMS + release
  publish (notes on stdin). Every regular file in the assets dir ships, so
  mirrors can publish upstream artifacts verbatim; sidecars (`upstream-*`,
  `*.sha256`, `release-info.env`) are stripped before upload.
- `prune-releases.sh` — keep-15 retention (`KEEP_RELEASES`).
- `lib.sh` — shared helpers (`fetch`, `fetch_flatcar`, `sha256_of`,
  `sha512_of`, `ensure_cmds`, `setup_linux_toolchain`, `verify_extract`).
  Sourced, never executed.

## Local development

Run the version check locally:

```sh
GH_TOKEN=$(gh auth token) GITHUB_REPOSITORY=teamoffy/tmfy-ci-releases \
  GITHUB_OUTPUT=/tmp/out sh scripts/check.sh
```

What runs where:

- **Published macOS targets** — aws-lc, zlib-ng, and zstd build natively on
  macOS with their smoke tests included. Bun repacks and verifies upstream's
  Linux and macOS zips on the Linux runner; sqlite-vec and llama-embedding
  repack upstream's binaries on each platform's native runner so their smoke
  tests load `vec0` and run `llama-cli`.
- **Published Linux-only targets** — postgres, valkey, clickhouse, pebble,
  typesense, libgit2, and flatcar-zfs-sysext. The first five and the sysext
  build reject non-Linux hosts; the sysext build additionally needs
  `systemd-nspawn`/`squashfs-tools`/`kmod` (installed via apt) and must run on
  the same architecture it targets — a kernel module is not cross-built. The
  libgit2 script also has a macOS build path for local testing, but the release
  workflow currently publishes only its Linux targets.
- **Mirrors** — k3s, flatcar, and the ci-tools repacks fetch+verify upstream
  artifacts; `flatcar-mirror.sh` pulls ~4 GB of images per run and the sysext
  build ~1 GB plus a full kernel-module compile, so local runs are slower than
  the binary repacks.

Lint:

```sh
shellcheck scripts/*.sh && actionlint
```

(`ubuntu-26.04*` runner labels are registered in `.github/actionlint.yaml`
until actionlint's runner database catches up.)
