# CI Releases

Prebuilt dependencies for CI pipelines, published as GitHub release assets.
[`release.yml`](.github/workflows/release.yml) runs daily (06:17 UTC), checks each
product's upstream for a new version, and builds, smoke-tests, and publishes
anything not yet released here. Product jobs run in parallel, and a failed
target does not cancel the other targets in its matrix. The newest 15 releases
per product are kept.

## Products

| Product | Tracks | Targets | Installs to |
|---|---|---|---|
| aws-lc | [aws/aws-lc](https://github.com/aws/aws-lc) | linux-x64, linux-arm64, darwin-arm64 | `/opt/aws-lc` |
| bun | [oven-sh/bun](https://github.com/oven-sh/bun) | linux-x64, linux-aarch64, darwin-x64, darwin-aarch64 | `bun-<platform>/` |
| zlib-ng | [zlib-ng/zlib-ng](https://github.com/zlib-ng/zlib-ng) | linux-x64, linux-arm64, darwin-arm64 | `/opt/zlib-ng` |
| postgres | PostgreSQL 18.x + timescaledb + pgvector + VectorChord | linux-x64, linux-arm64 | `/opt/postgresql` |
| valkey | [valkey](https://github.com/valkey-io/valkey) + valkey-bloom | linux-x64, linux-arm64 | `/opt/valkey` |
| clickhouse | [ClickHouse](https://github.com/ClickHouse/ClickHouse) LTS tags | linux-x64, linux-arm64 | `/opt/clickhouse` |
| pebble | [letsencrypt/pebble](https://github.com/letsencrypt/pebble) | linux-x64, linux-arm64 | `/opt/pebble` |
| typesense | [typesense](https://github.com/typesense/typesense) | linux-x64, linux-arm64 | `/opt/typesense` |
| zstd | [facebook/zstd](https://github.com/facebook/zstd) | linux-x64, linux-arm64, darwin-arm64 | `/opt/zstd` |
| libgit2 | [libgit2](https://github.com/libgit2/libgit2) + [libssh2](https://github.com/libssh2/libssh2) | linux-x64, linux-arm64 | `/opt/libgit2` |

Version tracking:

- **postgres** is a four-component combo (`<pg>-timescale<ts>-pgvector<vec>-vchord<vc>`);
  **valkey** is `<server>-bloom<bloom>`; **libgit2** is `<libgit2>-libssh2-<ssh2>`
  (the bundled SSH provider).
- valkey and pgvector publish no binary GitHub releases, so their git tags are
  tracked; clickhouse tracks LTS tags.

## Assets

Release tags are `<product>/v<version>`; assets are
`<product>-<version>-<platform>.tar.zst` (`tar | zstd --ultra -22`). Every
release ships `SHA256SUMS.txt`, and every built archive embeds `BUILD-INFO.txt`
with the upstream URLs, checksums, and build recipe. The bun archives are the
exception: they preserve the upstream contents and layout, so they carry no
`BUILD-INFO.txt`. `zstd` is preinstalled on `ubuntu-24.04+` and `macos-15+`
runners, so `tar --zstd -xf` works out of the box.

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

## Resolving the latest asset URL

Pin exact URLs where possible; to resolve the newest release for a product:

```sh
gh api --paginate repos/teamoffy/tmfy-ci-releases/releases --jq \
  '.[] | select(.tag_name | startswith("aws-lc/"))
   | .assets[] | select(.name | endswith("linux-arm64.tar.zst")) | .browser_download_url' |
  head -n 1
```

Releases come back newest first, so `head -n 1` wins. Paginating matters: with
ten products in one repo, a product that has not shipped in a while can fall off
the first page.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for pipeline internals, the scripts,
local runs, and force-rebuilds.

## License

The scripts and workflow in this repository are MIT licensed (see
[LICENSE](LICENSE)). The release assets are third-party software and carry
their upstream licenses, which are neither granted nor altered here; each
release lists the relevant terms in its notes.
