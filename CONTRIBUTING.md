# Contributing

## Pipeline

One workflow ([`release.yml`](.github/workflows/release.yml)), one run every
2nd day (06:17 UTC), 47 jobs:

1. **check** — resolves every product's target version from upstream (GitHub
   releases where they exist, git tags or index listings where they don't, the
   Flatcar channel's `version.txt`, and the GDS artifacts API for GraalVM) and
   decides whether that version is already released here. For the `oci-*`
   image mirrors it also probes each
   resolved tag on its registry, and for `oci-*`, `k3s`, `k3s-system`, the
   `ci-tools.txt` tools, `pulumi-plugins.txt`, and the stacks it emits a
   dynamic build matrix of what's missing.
   It also resolves [`stacks.txt`](scripts/stacks.txt): each cloud declares a
   target Kubernetes minor and the check computes the deployed set (newest
   k3s patch of that minor plus every `oci-images.txt` component through its
   source and k8s rule), dropping the cloud one minor until every coupled
   component resolves. The resolved sets are published as a content-addressed
   `stacks/v<hash>` release. Scheduled runs only mirror upstream releases at
   least 12h old: resolution falls back to the previous release where the
   source has history (Flatcar's channel does not, so it defers instead), and
   `workflow_dispatch` runs bypass the window — forcing a version is the
   escape route.
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
graalvm resolves its newest GDS-published JDK version when `version` is empty;
a supplied version must exist on GDS for all three platforms (the check fails
otherwise).
`oci-mirror` takes `<name>:<tag>` from
[`oci-images.txt`](scripts/oci-images.txt) (e.g. `cilium:v1.20.1`), or force a
single image directly with `product=oci-<name>` + `version=<tag>`; an empty
version rebuilds every image at its newest servable tag. `ci-tools` works the same
way over [`ci-tools.txt`](scripts/ci-tools.txt) — `product=ci-tools` +
`version=<name>:<tag>` or `product=<tool name>` + `version=<tag>`.
`pulumi-plugins` rebuilds every provider in
[`pulumi-plugins.txt`](scripts/pulumi-plugins.txt) at its latest release;
`product=pulumi-plugin-<name>` rebuilds one, and a `version` input picks that
exact upstream release. `stacks` republishes the resolved stacks release
(takes no version). From the Actions tab, or:

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
  Products that fan out into build matrices (`oci-*`, `k3s`, `k3s-system`,
  ci-tools, and `pulumi-plugins.txt`) use JSON matrices; `k3s-system`
  additionally emits a `(version, image)` cell matrix for its per-image
  build fan-out.
- `oci-images.txt` — tracked image mirrors: `<name> <registry/repo>
  <source> <sed> <k8s> <scope>`, one per line. `<source>` is a GitHub repo
  (newest release tag, transformed by `<sed>`, is the image tag), a literal
  `pin:<tag>`, a version-sorted `registry:<regex>` tag filter, or a
  `chart:<component>` reference. A release that is not yet promoted to the
  registry is not eligible, so the newest servable candidate wins. `<k8s>`
  marks how a component tracks a cloud's Kubernetes minor — `any` for
  independent ones, `cilium` for the cilium release that lists the minor in
  its e2e-tested set, `same:<name>`/`chart:<name>` to follow another
  component, or `minor`, `minor-short`, `minor-trail1` for versions that
  encode the minor — and `<scope>` is `shared` or the cloud that runs it.
  The check fails if a pinned tag is unavailable.
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
- `stacks.txt` — per-cloud Kubernetes targets: `<stack> k8s <minor>` per
  line. `check.sh` resolves each cloud's deployed set (the newest k3s patch
  of the target minor plus every component in `oci-images.txt` through its
  source and k8s rule), stepping the cloud down one minor whenever a coupled
  component cannot supply it. The resolved sets seed the build matrices and
  are published as a content-addressed `stacks/v<hash>` release whose
  `stacks.txt` asset lists `<stack> <product> <version-or-tag>` rows for
  consumers.
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
- `pulumi-plugins.txt` — tracked Pulumi resource provider binaries:
  `<name> <gh-repo>` per line. The version source is the repo's latest GitHub
  release; `check.sh` emits a per-(provider, platform) build matrix for the
  missing releases. Verified against the upstream GitHub asset digest.
- `pulumi-plugin-repack.sh <name> <version>` — fetch, verify, and repack one
  provider's upstream tarball for `PULUMI_PLUGIN_PLATFORM`
  (`linux-x64`|`linux-arm64`|`darwin-arm64`) into
  `pulumi-plugin-<name>-<version>-<platform>.tar.zst`, staging
  `pulumi-resource-<name>` at `usr/local/bin/`. Takes `PULUMI_PLUGIN_WORK`,
  `GH_TOKEN`.
- `graalvm-repack.sh <version> <platform> <gds-artifact-id> <sha256>` —
  download one GDS bundle, verify the sha256 from the API response and the
  object-storage `opc-meta-content-sha256` header, restage the JDK home as
  `home/` (flattening the macOS `Contents/Home` nesting), and pack a tar.zst.
  `check.sh` resolves the version plus per-platform artifact id + sha256 from
  the GDS artifacts API (the newest JDK version published for all platforms;
  a `version` input must exist on GDS for all platforms). Takes
  `GRAALVM_WORK`.
- `playwright-browsers-repack.sh <playwright-version>` — run playwright's own
  installer (`install --only-shell chromium webkit`) on the native runner so
  the archive carries the canonical `ms-playwright/` layout and
  `INSTALLATION_COMPLETE` markers; smoke-tests the headless shell. Upstream
  publishes no browser checksums, so the installer's validation is the
  upstream check. Linux legs must build on ubuntu-26.04 runners (the packed
  WebKit is distro-versioned). Takes `PW_BROWSERS_WORK`, `PW_BROWSERS_PLATFORM`.
- `<product>-build.sh <version>...` — build, smoke-test, and pack one product.
  The mirrors use `*-repack.sh` instead (`bun-repack.sh`, `graalvm-repack.sh`,
  `mysql-repack.sh`, `sqlite-vec-repack.sh`, `llama-embedding-repack.sh`,
  `playwright-browsers-repack.sh`):
  they verify upstream checksums where published and re-archive rather than
  compile. sqlite-vec, llama-embedding, and playwright-browsers repack on each
  target's native runner so their smoke tests (loading `vec0`, running
  `llama-cli`, running the headless shell) exercise the packaged binaries.
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
  tests load `vec0` and run `llama-cli`. playwright-browsers runs playwright's
  installer on each platform's native runner (a Linux leg must be ubuntu-26.04
  — the WebKit build is distro-versioned) and smoke-tests the packed headless
  shell. GraalVM repacks the resolved GDS
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
