# CI Releases

Prebuilt dependencies for CI pipelines, published as GitHub release assets.
[`release.yml`](.github/workflows/release.yml) runs every 2nd day (06:17 UTC),
checks each product's upstream for a new version, and builds, smoke-tests, and
publishes anything not yet released here. Scheduled runs only pick up releases
at least
12 hours old — a pulled or compromised upstream release usually disappears
inside that window — while `workflow_dispatch` runs bypass it. Product jobs
run in parallel, and a failed target does not cancel the other targets in its
matrix. The newest 45 releases per product are kept.

## Products

| Product | Tracks | Targets | Installs to |
|---|---|---|---|
| aws-lc | [aws/aws-lc](https://github.com/aws/aws-lc) | linux-x64, linux-arm64, darwin-arm64 | `/opt/aws-lc` |
| bun | [oven-sh/bun](https://github.com/oven-sh/bun) | linux-x64, linux-aarch64, darwin-x64, darwin-aarch64 | `bun-<platform>/` |
| graalvm | [Oracle GraalVM for JDK](https://www.oracle.com/downloads/graalvm-downloads.html) via the GDS artifacts API | linux-x64, linux-arm64, darwin-arm64 | `home/` (the JDK home) |
| zlib-ng | [zlib-ng/zlib-ng](https://github.com/zlib-ng/zlib-ng) | linux-x64, linux-arm64, darwin-arm64 | `/opt/zlib-ng` |
| postgres | PostgreSQL 18.x + timescaledb + pgvector + VectorChord | linux-x64, linux-arm64 | `/opt/postgresql` |
| mysql | [MySQL](https://github.com/mysql/mysql-server) latest LTS "Linux - Generic" repack | linux-arm64 | `/opt/mysql` |
| valkey | [valkey](https://github.com/valkey-io/valkey) + valkey-bloom | linux-x64, linux-arm64 | `/opt/valkey` |
| clickhouse | [ClickHouse](https://github.com/ClickHouse/ClickHouse) LTS tags | linux-x64, linux-arm64 | `/opt/clickhouse` |
| pebble | [letsencrypt/pebble](https://github.com/letsencrypt/pebble) | linux-x64, linux-arm64 | `/opt/pebble` |
| typesense | [typesense](https://github.com/typesense/typesense) | linux-x64, linux-arm64 | `/opt/typesense` |
| zstd | [facebook/zstd](https://github.com/facebook/zstd) | linux-x64, linux-arm64, darwin-arm64 | `/opt/zstd` |
| libgit2 | [libgit2](https://github.com/libgit2/libgit2) + [libssh2](https://github.com/libssh2/libssh2) | linux-x64, linux-arm64 | `/opt/libgit2` |
| sqlite-vec | [asg017/sqlite-vec](https://github.com/asg017/sqlite-vec) | linux-x64, linux-arm64, darwin-arm64 | `/opt/sqlite-vec` |
| llama-embedding | [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) `bNNNN` builds + [embeddinggemma-300M-GGUF](https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF) | linux-x64, linux-arm64, darwin-arm64 | `/opt/llama-embedding` |
| k3s | [k3s-io/k3s](https://github.com/k3s-io/k3s) | verbatim upstream files, not tar.zst | — |
| k3s-system | k3s release's `k3s-images.txt` | per-image OCI `.tar.zst` assets | — |
| flatcar | [Flatcar stable channel](https://www.flatcar.org/releases/) | verbatim upstream files, amd64 + arm64 | — |
| flatcar-zfs-sysext | Flatcar stable + [openzfs/zfs](https://github.com/openzfs/zfs) | squashfs `.raw`, amd64 + arm64 | `/etc/extensions` |
| ci-tools | see [`ci-tools.txt`](scripts/ci-tools.txt) | linux-x64, linux-arm64 | `usr/local/bin`, `opt/` |
| `pulumi-plugin-<name>` | Pulumi resource providers in [`pulumi-plugins.txt`](scripts/pulumi-plugins.txt) (latest release of each) | linux-x64, linux-arm64, darwin-arm64 | `usr/local/bin` |

Version tracking:

- **postgres** is a four-component combo (`<pg>-timescale<ts>-pgvector<vec>-vchord<vc>`);
  **valkey** is `<server>-bloom<bloom>`; **libgit2** is `<libgit2>-libssh2-<ssh2>`
  (the bundled SSH provider).
- valkey and pgvector publish no binary GitHub releases, so their git tags are
  tracked; clickhouse tracks LTS tags.
- **flatcar** and **flatcar-zfs-sysext** track the Flatcar *stable channel's*
  current release (`amd64-usr/current/version.txt`), not a GitHub repo —
  Flatcar has no releases API. The sysext version is the combo
  `<flatcar>-zfs<zfs>`.
- **graalvm** has no `releases/latest`-style upstream either: Oracle GDS
  bundles are content-addressed artifacts, so the newest JDK version
  published for all three platforms is resolved through the GDS artifacts
  API (the same endpoint `graalvm/setup-graalvm` uses) — artifact ids and
  sha256s come straight from the API at check time.
- **mysql** tracks the latest LTS line, not the Innovation stream: Oracle's
  apt repo names its LTS components `mysql-<line>-lts`, so the highest is
  the current LTS series (9.7 today); within it, the newest git tag whose
  generic tarball is actually published wins — the CDN can lag the tag.

## Mirrored node boot artifacts

Two products exist because every cluster node downloads them at boot:

- **k3s** — `k3s`/`k3s-arm64` binaries, `k3s-airgap-images-<arch>.tar.zst`,
  `k3s-images.txt`, and `install.sh`, byte-verbatim from
  [k3s-io/k3s](https://github.com/k3s-io/k3s). Binaries and airgap tarballs are
  verified against upstream `sha256sum-<arch>.txt` *and* their GitHub asset
  digests; `install.sh` is not a release asset upstream, so it is fetched from
  the tag's git tree with only its sha256 recorded in the notes. Airgap use:
  install the binary to `/usr/local/bin/k3s`, drop the airgap tarball into
  `/var/lib/rancher/k3s/agent/images/`, run `INSTALL_K3S_SKIP_DOWNLOAD=true
  sh install.sh`.
- **flatcar** — `flatcar-openstack-*` (UpCloud/Alibaba image imports),
  `flatcar-gce-*` (GCE import — amd64 only, upstream ships no arm64 GCE
  image), `flatcar-dev-container-*` (the kernel-matched build container),
  verified against upstream `.DIGESTS` sha512 sidecars. This is pin
  insurance: the channel CDN drops old versions while consumer pins keep
  referencing them.
- **flatcar-zfs-sysext** — OpenZFS built as a systemd-sysext squashfs image
  *inside the target Flatcar release's developer container*, so the module
  matches its kernel. Assets are `zfs-<zfs>-<flatcar>-<arch>.raw` — drop into
  `/etc/extensions` and run `systemd-sysext refresh`. The embedded,
  image-matched `extension-release.*` file pins `VERSION_ID=<flatcar>`, so a
  sysext only merges on the exact OS release it was built for.

## CI tools

`ci-tools.txt` drives verified mirrors of the public binaries and toolchains
the platform pins by sha256 (hadolint, osv-scanner, kubectl, helm, yq, pulumi,
aliyun-cli, upctl, actions-runner, node), plus `actionlint` for this repo's
own checks workflow. Each tool gets its own
`<name>/v<version>` release with `linux-x64`/`linux-arm64` tar.zst assets
staging `usr/local/bin/<tool>` or `opt/<name>/`. `node` tracks nodejs.org's
newest LTS point release — GitHub's latest is the Current line — and lands in
`opt/node/`. Downloads are checked against the GitHub asset digest, the
upstream `.sha256`/`.sha256sum` sidecar for non-GitHub hosts (kubectl, helm),
or a per-directory `SHASUMS256.txt` (nodejs.org). One release per tool means
each tracks its own latest independently; the whole set force-rebuilds via
`product=ci-tools`.

## Pulumi provider plugins

`pulumi-plugins.txt` lists the Pulumi resource provider binaries the deployments
use, one row per provider (`<name> <gh-repo>`). Each provider tracks its repo's
latest GitHub release. Each upstream release tarball
(`pulumi-resource-<name>-v<version>-<os>-<arch>.tar.gz`) is verified against its
GitHub asset digest and repacked as max-zstd (level 22) tar.zst for linux-x64,
linux-arm64, and darwin-arm64; the binary is staged at `usr/local/bin/`, so
extract at `/`. Releases are `pulumi-plugin-<name>/v<version>`. Several SDKs
share one provider plugin — the CRD extension SDKs all use `kubernetes` — so
they resolve to that single release.

## OCI image mirrors

`oci-<name>/v<version>` releases repack upstream platform images as **zstd:chunked**
OCI image layouts (`skopeo copy --all --dest-compress-format zstd:chunked
--dest-compress-level 19`), one `<product>-<version>-oci.tar.zst` asset per
image covering every published architecture. The tracked set lives in
[`oci-images.txt`](scripts/oci-images.txt): DaemonSets, CSI sidecars, cloud
controllers, and upgrade images. Tags come from each row's source — an
upstream GitHub release, a version-sorted registry tag filter, or a
chart-pinned tag derived from another component — filtered to what is
actually pushed to the registry, since a release can precede (or skip)
registry promotion and the newest servable candidate wins. A row with no
derivable source can still pin a literal `pin:<tag>`; the check fails if a
pinned tag is unavailable. The `<k8s>` and `<scope>` columns feed the
per-cloud stacks resolution below.

Each k3s version also has a `k3s-system/v<k3s-version>` release. It mirrors
pause, coredns, local-path-provisioner, klipper-helm, and busybox as individual
`oci-<image>-<tag>-oci.tar.zst` assets. The verified `k3s-images.txt` from that
k3s release supplies the list; traefik, metrics-server, and klipper-lb are
skipped because the deployment disables them.

## Per-cloud stacks

[`stacks.txt`](scripts/stacks.txt) declares each cloud's target Kubernetes
version — `gcp k8s latest` (the newest k3s minor) or an explicit minor such
as `1.37` to hold it back — and nothing else. `check.sh` computes the
deployed set: the newest k3s patch of that minor plus every in-scope
component in [`oci-images.txt`](scripts/oci-images.txt), resolved through
that row's source and its `<k8s>` coupling rule. A component that cannot
supply the target minor drops the whole cloud one minor and resolution
retries, so a cloud never runs ahead of its slowest dependency and moves up
by itself as soon as that dependency catches up. Coupling today: `cilium`
(and its operator and envoy, which follow it) must list the minor in
cilium's documented e2e-tested Kubernetes set — cilium runs on every node,
so it gates upgrades; `gcp-ccm` and `alicloud-csi-plugin` must match the
minor; `oci-ccm` may trail by one. Everything else tracks latest and never
holds a cloud back. A `k3s` resolution carries the k3s files, the
k3s-system images, and `rancher/k3s-upgrade` at the same version.

The resolved sets seed the build matrices and are published as a
content-addressed `stacks/v<hash>` release whose `stacks.txt` asset carries
one `<cloud> <product> <version-or-tag>` row per deployed version — that is
what consumers read, not the declaration file. A cloud whose new set has an
upstream artifact that is not servable yet is held out of the published file
until a later run; an unchanged resolution republishes nothing.

`oci-images.txt` remains the mirror's tracked set (each image at upstream
latest) — the stacks resolution picks which of those versions each cloud
runs, so a lagging CCM holds its cloud on the previous minor while the mirror
still carries the newer images.

```sh
curl -fsSL --retry 3 -O "https://github.com/teamoffy/tmfy-ci-releases/releases/download/oci-cilium/v1.20.2/oci-cilium-1.20.2-oci.tar.zst"
tar --zstd -xf oci-cilium-1.20.2-oci.tar.zst
skopeo copy --all --preserve-digests oci:oci-cilium-1.20.2:v1.20.2 docker://<registry>/<repo>:v1.20.2
```

`--preserve-digests` keeps the zstd:chunked metadata. A containers/storage
client, such as Podman or CRI-O, can then use range requests and reuse existing
chunks when partial pulls are enabled. This is not the eStargz format used by
stargz-snapshotter. The destination registry must accept OCI manifests with
zstd layers; preserving digests prevents transparent recompression. The
extracted directory also works with OCI-layout consumers directly, including
an S3 registry sync or `skopeo copy oci:... oci-archive:...` for
`ctr images import`.

## Assets

Release tags are `<product>/v<version>`. Native-product assets are named
`<product>-<version>-<platform>.tar.zst` and use `tar | zstd --ultra -22`; OCI
asset names and layouts are described above. Every release ships
`SHA256SUMS.txt`. Compiled-product archives embed `BUILD-INFO.txt` with
upstream URLs, checksums, and the build recipe. Bun preserves the upstream
archive layout, GraalVM repacks the upstream JDK home as-is, the verbatim
mirrors (k3s, flatcar) ship upstream files untouched, the ci-tools and
pulumi-plugin repacks carry only their staged binaries, and OCI assets are
self-contained image layouts — none of those carries `BUILD-INFO.txt`; their
provenance is recorded in the release notes. `zstd` is
preinstalled on `ubuntu-24.04+` and `macos-15+` runners, so
`tar --zstd -xf` works out of the box.

## Usage

```yaml
- run: |
    curl -fsSL --retry 3 -O "https://github.com/teamoffy/tmfy-ci-releases/releases/download/zstd/v1.5.7/zstd-1.5.7-linux-arm64.tar.zst"
    sudo tar --zstd -xf zstd-1.5.7-linux-arm64.tar.zst -C /
    sudo ldconfig   # products with shared libs, Linux only
```

Map `${RUNNER_OS}`/`${RUNNER_ARCH}` to the platform suffixes in the table
(`linux-*`, `darwin-*`). Watch the 64-bit ARM spelling: bun follows upstream and
uses `aarch64`, every other product uses `arm64`.

Product notes:

- **aws-lc**, **zlib-ng**: shared libs — run `sudo ldconfig` on Linux. zlib-ng
  exposes the zlib-ng API (`zlib-ng.h`, `-lz-ng`); point builds at the prefix via
  pkg-config or `-I`/`-L`. aws-lc macOS dylibs use `/opt/aws-lc/lib` install names.
- **postgres**: server + timescaledb + pgvector + vchord + pgcrypto. Cluster
  creation and `shared_preload_libraries=timescaledb,vchord` are consumer-side.
- **mysql**: repack of Oracle's "Linux - Generic" binaries for CI test lanes —
  `opt/mysql/bin/{mysqld,mysql,mysqladmin}`, `lib/`, `share/`; the runtime deps
  the ubuntu images lack (libaio, libnuma, ncurses) are bundled into
  `lib/private/`, which the binaries' `$ORIGIN/../lib/private` RUNPATH covers.
  Datadir init (`--initialize-insecure`), users, and flags are consumer-side.
- **valkey**: bloom module at `/opt/valkey/modules/libvalkey_bloom.so`.
- **clickhouse**: binaries in `usr/bin`, config in `etc/clickhouse-server`.
- **pebble**: binaries in `bin/`, test config/certs in `test/`.
- **typesense**: single `typesense-server` binary.
- **zstd**, **libgit2**: prebuilt alternatives to installing the development
  packages with apt. Point consumers at the prefix with
  `-I/opt/<name>/include -L/opt/<name>/lib`,
  `PKG_CONFIG_PATH=/opt/<name>/lib/pkgconfig`, or CMake `ZSTD_ROOT` /
  `GIT2_ROOT`. libgit2 bundles libssh2.
- **bun**: repack of the standard official zips. The x64 assets require AVX2;
  no `-baseline` variants are mirrored. The inner layout is unchanged, so
  extract without `sudo`/`-C /`, then
  `install bun-<platform>/bun ~/.bun/bin/bun`. Inside Actions, pinning a version
  in `oven-sh/setup-bun` is usually simpler, since its cache only engages for
  pinned versions; this mirror is for cold starts and non-Actions use.
- **graalvm**: repack of Oracle GDS JDK bundles resolved at check time (the
  newest JDK version published for all platforms; artifact id + sha256 come
  from the GDS API). The archive root is `home/`, so extract at the
  destination (`tar --zstd -xf <asset> -C <dest>`) and use `<dest>/home` as
  `JAVA_HOME` (`<dest>/home/bin/java`); the macOS bundle's `Contents/Home`
  nesting is flattened to the same layout.
- **sqlite-vec**: repack of upstream's loadable `vec0` extension at
  `opt/sqlite-vec/lib/vec0.so` (`vec0.dylib` on macOS). Verified against
  upstream `checksums.txt` and smoke-tested by loading the extension
  (`vec_version()`); consumers load it by absolute path, e.g.
  `sqlite3_load_extension` or a `*_SQLITE_VEC_EXTENSION`-style env var.
- **llama-embedding**: llama.cpp's official per-platform binary tarball plus
  the pinned EmbeddingGemma GGUF — a semantic-search test fixture.
  `opt/llama-embedding/native/` holds the libraries and CLI tools;
  `opt/llama-embedding/models/` holds `embeddinggemma-300M-Q8_0.gguf`. The
  version is llama.cpp's `bNNNN` tag verbatim (`llama-embedding/vb11056`) —
  upstream marks those builds prerelease, so the newest `b*` tag carrying all
  three bin tarballs is tracked rather than `releases/latest`. The
  model is revision-pinned in the repack script and bumps via a forced rebuild.
  The archive includes the Gemma terms, prohibited-use policy, required notice,
  and modification notice. Smoke-tested by running `llama-cli --version`.

## Resolving the latest asset URL

Pin exact URLs where possible; to resolve the newest release for a product:

```sh
gh api --paginate repos/teamoffy/tmfy-ci-releases/releases --jq \
  '.[] | select(.tag_name | startswith("aws-lc/"))
   | .assets[] | select(.name | endswith("linux-arm64.tar.zst")) | .browser_download_url' |
  head -n 1
```

Releases come back newest first, so `head -n 1` wins. Paginating matters: with
this many product lines in one repo, a product that has not shipped in a while
can fall off the first page.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for pipeline internals, the scripts,
local runs, and force-rebuilds.

## License

The scripts and workflow in this repository are MIT licensed (see
[LICENSE](LICENSE)). The release assets are third-party software and carry
their upstream licenses, which are neither granted nor altered here; each
release lists the relevant terms in its notes.
