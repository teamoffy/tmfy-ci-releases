# Contributing

## Pipeline

One workflow ([`release.yml`](.github/workflows/release.yml)), one daily run
(06:17 UTC), 22 jobs:

1. **check** — resolves every product's target version from upstream (GitHub
   releases where they exist, git tags or index listings where they don't) and
   decides whether that version is already released here.
2. **build-\<product\>** — one parallel job per product with its own platform
   matrix. `fail-fast: false` lets the other targets finish if one target fails.
   Every product is smoke-tested before publishing: compiled-and-run for the
   libraries, a live server boot for the services, checksum-verified repacks
   for the mirrors.
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
`9.1.2/1.0.1`, libgit2 `1.9.7/1.11.1`. From the Actions tab, or:

```sh
gh workflow run release.yml -f product=zstd -f version=1.5.7
```

PostgreSQL is pinned to 18.x — major bumps need a new VectorChord `.deb`
target, so bump them deliberately via a forced version.

## Scripts

- `check.sh` — version resolution for all products. Reads `FORCE_PRODUCT` /
  `FORCE_VERSION`, writes `<product>_version` / `<product>_build` lines to
  `GITHUB_OUTPUT`.
- `<product>-build.sh <version>...` — build, smoke-test, and pack one product
  (bun is the odd one out: `bun-repack.sh`, since it only mirrors). Multi-component
  products take one arg per component (postgres 4, valkey 2, libgit2 2). Each
  takes a `*_PLATFORM` env (e.g. `linux-x64`) and a `*_WORK` work dir.
- `pack.sh <dir> <out.tar.zst> <entry>` — max-compressed tar.zst + sha256
  sidecar.
- `publish-release.sh <tag> <title> <assets-dir>` — SHA256SUMS + release
  publish (notes on stdin).
- `prune-releases.sh` — keep-15 retention (`KEEP_RELEASES`).
- `lib.sh` — shared helpers (`fetch`, `sha256_of`, `ensure_cmds`,
  `setup_linux_toolchain`, `verify_extract`). Sourced, never executed.

## Local development

Run the version check locally:

```sh
GH_TOKEN=$(gh auth token) GITHUB_REPOSITORY=teamoffy/tmfy-ci-releases \
  GITHUB_OUTPUT=/tmp/out sh scripts/check.sh
```

What runs where:

- **Published macOS targets** — aws-lc, zlib-ng, and zstd build natively on
  macOS with their smoke tests included. Bun repacks and verifies upstream's
  Linux and macOS zips on the Linux runner.
- **Published Linux-only targets** — postgres, valkey, clickhouse, pebble,
  typesense, and libgit2. The first five reject non-Linux hosts. The libgit2
  script also has a macOS build path for local testing, but the release workflow
  currently publishes only its Linux targets.

Lint:

```sh
shellcheck scripts/*.sh && actionlint
```

(`ubuntu-26.04*` runner labels are registered in `.github/actionlint.yaml`
until actionlint's runner database catches up.)
