# Contributing

## Pipeline

One workflow ([`release.yml`](.github/workflows/release.yml)), one run every
2nd day (06:17 UTC), 44 jobs:

1. **check** — resolves every product's target version from upstream (GitHub
   releases where they exist, git tags or index listings where they don't, and
   the Flatcar channel's `version.txt`) and decides whether that version is
   already released here. For the `oci-*` image mirrors it also probes each
   resolved tag on its registry, and for `oci-*`, `k3s`, `k3s-system`, the
   `ci-tools.txt` tools, and `pulumi-plugins.txt` it emits a dynamic build
   matrix of what's missing.
   It also checks [`stacks.txt`](scripts/stacks.txt). A stack is added to the
   build matrices only when all of its pinned versions are available upstream
   or already released here. Scheduled runs only mirror upstream releases at
   least 12h old: resolution falls back to the previous release where the
   source has history (Flatcar's channel does not, so it defers instead),
   `stacks.txt` pins are human-vetted and exempt, and `workflow_dispatch`
   runs bypass the window — forcing a version is the escape route.
2. **build-\<product\>** — one parallel job per product with its own platform
   matrix. `fail-fast: false` lets the other targets finish if one target fails.
   Every product is smoke-tested before publishing: compiled-and-run for the
   libraries, a live server boot for the services, checksum-verified repacks
   for the mirrors, layer-format verification for the OCI repacks.
3. **release-\<product\>** — assembles `SHA256SUMS.txt` and publishes the
   release with notes (upstream URLs/checksums, build recipe, license).
4. **cleanup** — prunes each product's releases beyond the newest
   `KEEP_RELEASES` (45) so fallback versions survive if automation stalls;
   set to `1` for strictly latest-only.

## Force-rebuilding a version

Dispatch `release.yml` with `product` set — that product always rebuilds and
replaces its release assets and notes in place, while the rest get their normal
scheduled check.
`version` is optional (upstream latest if empty); multi-component products
take slash-joined versions: postgres `18.6/2.29.2/0.8.6/1.1.1`, valkey
`9.1.2/1.0.1`, libgit2 `1.9.7/1.11.1`, flatcar-zfs-sysext `4593.2.5/2.4.4`.
graalvm accepts only its pinned version: the artifacts are pinned in
[`graalvm.txt`](scripts/graalvm.txt) and a supplied version must equal that
pin (GDS has no "latest" — bump the manifest to change versions).
`oci-mirror` takes `<name>:<tag>` from
[`oci-images.txt`](scripts/oci-images.txt) (e.g. `cilium:v1.20.1`), or force a
single image directly with `product=oci-<name>` + `version=<tag>`; an empty
version rebuilds every image at its newest servable tag. `ci-tools` works the same
way over [`ci-tools.txt`](scripts/ci-tools.txt) — `product=ci-tools` +
`version=<name>:<tag>` or `product=<tool name>` + `version=<tag>`.
`pulumi-plugins` rebuilds every pin in
[`pulumi-plugins.txt`](scripts/pulumi-plugins.txt);
`product=pulumi-plugin-<name>` rebuilds one, and a `version` input must equal
the manifest pin. From the Actions tab, or:

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
  `FORCE_VERSION` and writes versions and build decisions to `GITHUB_OUTPUT`.
  Products that can build several releases in one run (`oci-*`, `k3s`,
  `k3s-system`, and ci-tools) use JSON matrices; `k3s-system` additionally
  emits a `(version, image)` cell matrix for its per-image build fan-out.
- `oci-images.txt` — tracked image mirrors: `<name> <registry/repo>
  <gh repo|pin:tag> <sed>`, one per line. `<gh repo>`'s newest release tag,
  transformed by `<sed>`, is the image tag to mirror — except a release that
  is not yet promoted to the registry is not eligible, so the newest servable
  tag wins. `pin:<tag>` is a literal tag for chart-pinned images. The check
  fails if a pinned tag is unavailable.
- `oci-mirror.sh <name> <repo:tag>` — `skopeo copy` re-encode of one upstream
  image's linux platforms to a zstd:chunked OCI layout (windows/darwin index
  entries are dropped: the nodes only pull linux, and the Windows variants
  carry multi-GB layers). Layer-format verification follows, then `pack.sh`
  level 12 (the blobs are already compressed) to a `-oci.tar.zst` asset plus a
  `release-info.env` provenance file. Takes an `OCI_WORK` work dir.
- `k3s-mirror.sh <version>` — verbatim mirror of the k3s node binaries, zstd
  airgap tarballs, `k3s-images.txt`, and `install.sh`; binaries/airgap are
  verified against upstream `sha256sum-<arch>.txt` and everything else against
  GitHub asset digests. Takes `K3S_WORK` and `GH_TOKEN`.
- k3s-system images — `check.sh` resolves each built k3s version's image list
  from its own `k3s-images.txt` (minus the components the deployment
  disables) into the `k3s_system_images_matrix`; `build-k3s-system` runs
  `oci-mirror.sh` per (version, image) cell and `release-k3s-system` merges a
  version's cells into one `k3s-system/v<version>` release.
- `stacks.txt` — per-cloud deployed node sets: `<stack> <product> <tag>` per
  line. Clouds track k8s versions independently. `check.sh` probes every row
  and queues the stack only if each release already exists or its upstream tag
  is available. A `k3s` row covers `k3s`, `k3s-system`, and
  `oci-k3s-upgrade`; `oci-*` rows add cells to the image build matrix. Update
  all related rows in one PR when bumping a cloud.
- `flatcar-mirror.sh <version> <arch> <upstream-file> <kind>` — verbatim
  mirror of one release artifact, verified against the upstream `.DIGESTS`
  sha512 sidecar. The artifact set is the `build-flatcar` matrix in
  `release.yml` (GCE is amd64-only: upstream ships no arm64 GCE image).
  Takes `FLATCAR_WORK`, `FLATCAR_CHANNEL` (default `stable`).
- `flatcar-zfs-sysext-build.sh <flatcar> <zfs>` — OpenZFS compiled against the
  target Flatcar kernel inside that release's developer container
  (`systemd-nspawn`), packed as a squashfs `.raw` sysext with the
  `VERSION_ID=<flatcar>` merge gate. Same-arch only. Takes
  `FLATCAR_ZFS_PLATFORM`, `FLATCAR_ZFS_WORK`, `FLATCAR_CHANNEL`, `GH_TOKEN`.
- `ci-tools.txt` — tracked tools: `<name> <gh-repo> <x64-url> <arm64-url>
  <mode>` per line. `{tag}`/`{ver}` expand in the URLs; `mode` is `bin` (bare
  binary), `tarbin:<member>` (one binary out of an archive), or `tardir`
  (whole archive to `opt/<name>`). The version source is `<gh-repo>`'s latest
  GitHub release, except `nodejs/node`, which resolves to the newest LTS point
  release from nodejs.org's `dist/index.json` (its GitHub latest is the
  Current line) — see `tool_latest` in `check.sh`.
- `tool-repack.sh <name> <tag>` — fetch + verify + repack one ci-tools.txt row
  into `linux-x64`/`linux-arm64` tar.zst assets plus `release-info.env`.
  GitHub-hosted assets verify via the asset digest; other hosts via the
  `.sha256`/`.sha256sum` sidecar or a per-directory
  `SHASUMS256.txt`/`sha256sums.txt` (nodejs.org's convention). Takes
  `CI_TOOLS_WORK`, `GH_TOKEN`.
- `pulumi-plugins.txt` — pinned Pulumi resource provider binaries:
  `<name> <version> <gh-repo>` per line. The manifest is the version source
  (bump it to mirror a new provider version); `check.sh` emits a per-(provider,
  platform) build matrix for the missing releases. Verified against the
  upstream GitHub asset digest.
- `pulumi-plugin-repack.sh <name>` — fetch, verify, and repack one provider's
  upstream tarball for `PULUMI_PLUGIN_PLATFORM`
  (`linux-x64`|`linux-arm64`|`darwin-arm64`) into
  `pulumi-plugin-<name>-<version>-<platform>.tar.zst`, staging
  `pulumi-resource-<name>` at `usr/local/bin/`. Takes `PULUMI_PLUGIN_WORK`,
  `GH_TOKEN`.
- `graalvm.txt` — pinned Oracle GraalVM for JDK bundles: one `version` row
  plus `<platform> <gds-artifact-id> <sha256>` rows for linux-x64, linux-arm64,
  and darwin-arm64. GDS exposes no "latest" and artifact ids are immutable, so
  a version bump is a manifest edit; the `version` value names the release tag.
- `graalvm-repack.sh <version>` — download each pinned GDS bundle, verify the
  sha256 pin and the object-storage `opc-meta-content-sha256` header, restage
  the JDK home as `home/` (flattening the macOS `Contents/Home` nesting), and
  pack a tar.zst. Takes `GRAALVM_WORK`, `GRAALVM_PLATFORMS`.
- `<product>-build.sh <version>...` — build, smoke-test, and pack one product.
  The mirrors use `*-repack.sh` instead (`bun-repack.sh`, `graalvm-repack.sh`,
  `mysql-repack.sh`, `sqlite-vec-repack.sh`, `llama-embedding-repack.sh`):
  they verify upstream checksums where published and re-archive rather than
  compile. sqlite-vec and llama-embedding repack on each target's native
  runner so their smoke tests (loading `vec0`, running `llama-cli`) exercise
  the packaged binaries.
  Multi-component products take one arg per component (postgres 4, valkey 2,
  libgit2 2). Each takes a `*_PLATFORM` env (e.g. `linux-x64`) and a `*_WORK`
  work dir.
- `pack.sh <dir> <out.tar.zst> <entry> [zstd-level]` — tar.zst + sha256
  sidecar; level defaults to 22 (max), already-compressed payloads pass a
  low level.
- `publish-release.sh <tag> <title> <assets-dir>` — SHA256SUMS + release
  publish (notes on stdin). Every regular file in the assets dir ships, so
  mirrors can publish upstream artifacts verbatim; sidecars (`upstream-*`,
  `*.sha256`, `release-info.env`) are stripped before upload.
- `prune-releases.sh` — keep-45 retention (`KEEP_RELEASES`).
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
  tests load `vec0` and run `llama-cli`. GraalVM repacks the pinned GDS
  bundles on the Linux runner for all three platforms — the repack is
  platform-independent, and its post-pack check re-extracts `home/bin/java`
  rather than executing the JDK. The `pulumi-plugin-*` repack is
  platform-independent too: it verifies and re-archives upstream's per-platform
  tarballs on the Linux runner.
- **Published Linux-only targets** — postgres, mysql, valkey, clickhouse,
  pebble, typesense, libgit2, and flatcar-zfs-sysext. The first six and the
  sysext build reject non-Linux hosts; the sysext build additionally needs
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
