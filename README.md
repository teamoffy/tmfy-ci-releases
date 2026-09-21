# CI Releases

Prebuilt dependencies for CI pipelines, published as GitHub release assets.
[`release.yml`](.github/workflows/release.yml) runs daily (06:17 UTC), checks each
product's upstream for a new version, and builds, smoke-tests, and publishes
anything not yet released here. Product jobs run in parallel, and a failed
target does not cancel the other targets in its matrix. The newest 45 releases
per product are kept.

## Products

| Product | Tracks | Targets | Installs to |
|---|---|---|---|
| aws-lc | [aws/aws-lc](https://github.com/aws/aws-lc) | linux-x64, linux-arm64, darwin-arm64 | `/opt/aws-lc` |
| bun | [oven-sh/bun](https://github.com/oven-sh/bun) | linux-x64, linux-aarch64, darwin-x64, darwin-aarch64 | `bun-<platform>/` |
| graalvm | [Oracle GraalVM for JDK](https://www.oracle.com/downloads/graalvm-downloads.html) GDS pins ([`graalvm.txt`](scripts/graalvm.txt)) | linux-x64, linux-arm64, darwin-arm64 | `home/` (the JDK home) |
| zlib-ng | [zlib-ng/zlib-ng](https://github.com/zlib-ng/zlib-ng) | linux-x64, linux-arm64, darwin-arm64 | `/opt/zlib-ng` |
| postgres | PostgreSQL 18.x + timescaledb + pgvector + VectorChord | linux-x64, linux-arm64 | `/opt/postgresql` |
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
- **graalvm** has no upstream "latest" either: Oracle GDS artifact ids are
  immutable per bundle, so the version and per-platform sha256 pins live in
  [`graalvm.txt`](scripts/graalvm.txt) — a bump is a manifest edit followed by
  a forced `graalvm` rebuild.

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

## OCI image mirrors

`oci-<name>/v<version>` releases repack upstream platform images as **zstd:chunked**
OCI image layouts (`skopeo copy --all --dest-compress-format zstd:chunked
--dest-compress-level 19`), one `<product>-<version>-oci.tar.zst` asset per
image covering every published architecture. The tracked set lives in
[`oci-images.txt`](scripts/oci-images.txt): DaemonSets, CSI sidecars, cloud
controllers, and upgrade images. Tags follow each upstream project's newest
GitHub release whose image is actually pushed to the registry — a release can
precede (or skip) registry promotion, so the newest servable tag wins.
Images without a suitable release source use a literal `pin:<tag>`; the check
fails if that tag is unavailable.

Each k3s version also has a `k3s-system/v<k3s-version>` release. It mirrors
pause, coredns, local-path-provisioner, klipper-helm, and busybox as individual
`oci-<image>-<tag>-oci.tar.zst` assets. The verified `k3s-images.txt` from that
k3s release supplies the list; traefik, metrics-server, and klipper-lb are
skipped because tea disables them.

## Per-cloud stacks

[`stacks.txt`](scripts/stacks.txt) declares the k3s and node-image versions for
each cloud. Clouds can move to a new k8s version independently.

A stack is queued only when every row is available upstream or already has an
exact release here. A `k3s` row covers the k3s files, the k3s-system images,
and `rancher/k3s-upgrade` at the same version. The workflow can build upstream
latest and several stack-pinned versions in one run. Update all related rows
together when bumping a cloud.

Latest-version checks still run alongside the stack pins, so an older pin and
a newer upstream release can both be built in the same run.

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
`SHA256SUMS.txt`. Product archives embed `BUILD-INFO.txt` with upstream URLs,
checksums, and the build recipe. Bun preserves the upstream archive layout,
GraalVM repacks the upstream JDK home as-is, and OCI assets are self-contained
image layouts, so none of those carries `BUILD-INFO.txt`; their provenance is
recorded in the release notes. `zstd` is
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
- **graalvm**: repack of the pinned Oracle GDS JDK bundles. The archive root is
  `home/`, so extract at the destination
  (`tar --zstd -xf <asset> -C <dest>`) and use `<dest>/home` as `JAVA_HOME`
  (`<dest>/home/bin/java`); the macOS bundle's `Contents/Home` nesting is
  flattened to the same layout. GDS has no "latest" — version bumps edit
  `scripts/graalvm.txt` and force-rebuild `graalvm`.
- **sqlite-vec**: repack of upstream's loadable `vec0` extension at
  `opt/sqlite-vec/lib/vec0.so` (`vec0.dylib` on macOS). Verified against
  upstream `checksums.txt` and smoke-tested by loading the extension
  (`vec_version()`); consumers load it by absolute path, e.g.
  `sqlite3_load_extension` or a `*_SQLITE_VEC_EXTENSION`-style env var.
- **llama-embedding**: llama.cpp's official per-platform binary tarball plus
  the pinned EmbeddingGemma GGUF — the codetel semantic-search test fixture.
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
