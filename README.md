# TollGate OpenWrt Feed

An OpenWrt package feed that builds **`tollgate-wrt`** from the upstream
[`OpenTollGate/tollgate-module-basic-go`](https://github.com/OpenTollGate/tollgate-module-basic-go)
source using OpenWrt's `golang-package.mk`.

TollGate turns an OpenWrt router into a Cashu-powered payment gateway for
internet access. This feed produces a single package that installs both
binaries — the `tollgate-wrt` service and the `tollgate` CLI — plus its init
scripts, UCI defaults, captive-portal site, and hotplug hooks.

The upstream repository is **not modified** by this feed. It is downloaded,
built, and packaged entirely from the release source tarball.

## Why a separate feed repo

An earlier attempt ([upstream PR #125](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/125))
tried to restructure upstream's Go source (`src/` → repo root) to satisfy
`golang-package.mk`. That touched ~120 files and could not be rebased.
`golang-package.mk` accepts `GO_PKG` pointing at a subdirectory, so **no
upstream restructure is needed**. Keeping the feed glue in this separate repo
means:

- zero rebase collisions with upstream development, forever;
- the package is usable as a `src-git` feed *today*;
- the `net/tollgate-wrt/` directory lifts cleanly into a future PR against
  [`openwrt/packages`](https://github.com/openwrt/packages) as a small,
  reviewable addition.

## Using the feed

Add it to an OpenWrt build:

```sh
echo "src-git tollgate https://github.com/FreedomTechFeed/feed.git" >> feeds.conf
./scripts/feeds update tollgate
./scripts/feeds install tollgate-wrt
```

Then enable it in `make menuconfig` under **Network → Captive Portals →
tollgate-wrt**, and build.

> The package depends on `nodogsplash` and `jq`, which come from the standard
> `packages` feed — keep that feed enabled too. `golang-package.mk` (the Go
> build helpers) also comes from the `packages` feed.

## How it builds two binaries in one package

The upstream source has **two Go modules**:

- the service, the main module at `src/` (`github.com/OpenTollGate/tollgate-module-basic-go`),
- the CLI, a self-contained module at `src/cmd/tollgate-cli/` (`module tollgate-cli`).

`golang-package.mk` builds one module per Makefile. The `Makefile` overrides
`Build/Compile` to: (1) build the service through the framework helper, then
(2) build the CLI manually from its own module dir, reusing the framework's
exported cross-compile environment. One package, both binaries —
`/usr/bin/tollgate-wrt` and `/usr/bin/tollgate`.

## Syncing a new upstream release

```sh
scripts/sync-from-upstream.sh v0.5.1
```

This downloads the tarball for the given tag, recomputes `PKG_HASH`, sets
`PKG_VERSION`, and re-vendors `packaging/files/` into `net/tollgate-wrt/files/`.
Review the diff (the captive-portal-site assets change every release — that's
expected) and commit.

## Binary feed (no build needed)

CI publishes ready-made per-architecture package indices so a router can
install `tollgate-wrt` without compiling anything. On OpenWrt 24.10+
(apk-based) devices:

```sh
echo "src/gz tollgate https://freedomtechfeed.github.io/feed/<arch>/" >> /etc/opkg/customfeeds.conf
echo "https://freedomtechfeed.github.io/feed/<arch>/" >> /etc/apk/repositories
apk update
apk add tollgate-wrt
```

Replace `<arch>` with your device's OpenWrt **arch tuple** — e.g.
`aarch64_cortex-a53` (GL-MT6000 / mediatek-filogic), `mipsel_24kc`
(GL-MT3000 / ramips-mt7621), or `x86_64`. Check yours with
`opkg print-architecture` or `apk --print-arch`. The same per-arch
directories serve `Packages.gz` for opkg-based (pre-24.10) releases; the
full pipeline — tag → release assets → indices → gh-pages — is documented
in [`docs/feed-index.md`](docs/feed-index.md).

## Validation

`.github/workflows/validate-feed.yml` runs three jobs:

1. **validate** — Makefile lint (fields present, no `REPLACES`), `PKG_HASH`
   verified against the live tarball, every referenced `files/` path exists.
2. **go-smoke** — fast `go build` of both modules for amd64/arm64/mipsle
   (no SDK, catches source breakage quickly).
3. **build-sdk** — the authoritative proof: a real OpenWrt SDK compile of the
   package via `golang-package.mk`, including the nested CLI-module build.

The SDK job is the gate before submitting upstream. See [`PLAN.md`](PLAN.md)
for the full design and the highest-risk item.

## Submitting to `openwrt/packages` (future)

When this feed is green in CI, the `net/tollgate-wrt/` directory can be lifted
into a PR against `openwrt/packages`. The only change required is the
`golang-package.mk` include path:

```diff
-include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk
+include ../../lang/golang/golang-package.mk
```

Follow the
[`openwrt/packages` contributing guide](https://github.com/openwrt/packages/blob/master/CONTRIBUTING.md)
(Signed-off-by, commit-message format) when opening that PR.

## License

`GPL-3.0-only` — matches upstream. The built `tollgate-wrt` package ships
upstream's `LICENSE`.
