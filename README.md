# TollGate OpenWrt Feed

An OpenWrt package feed that builds **`tollgate-wrt`** from the upstream
[`OpenTollGate/tollgate-module-basic-go`](https://github.com/OpenTollGate/tollgate-module-basic-go)
source using OpenWrt's `golang-package.mk`.

TollGate turns an OpenWrt router into a Cashu-powered payment gateway for
internet access. This feed produces a single package that installs both
binaries — the `tollgate-wrt` service and the `tollgate` CLI — plus its init
scripts, UCI defaults, captive-portal site, and hotplug hooks.

The upstream repository is **not modified** by this feed. It is downloaded,
built, and packaged entirely from the release source tarball. The runtime
files (init script, UCI defaults, nftables.d drop-ins, hotplug hooks, man
pages, captive-portal site) are not vendored here either — the Makefile
installs them straight from the tarball's `packaging/files/` tree
(`$(PKG_TARBALL_DIR)`), which upstream ships OpenWrt-shaped because it builds
its own `.ipk` from the same tree.

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
scripts/sync-from-upstream.sh v0.6.0-alpha1
```

This downloads the tarball for the given tag, recomputes `PKG_HASH`, and sets
`PKG_SOURCE_VERSION` (the upstream git tag) plus the apk-legal `PKG_VERSION`
(hyphens mapped to underscores). The runtime files need no sync step — they
ride along in the tarball's `packaging/files/` and are installed from there
at build time. Review the diff and commit.

## Validation

`.github/workflows/validate-feed.yml` runs three jobs:

1. **validate** — Makefile lint (fields present, no `REPLACES`), `PKG_HASH`
   verified against the live tarball, every `packaging/files/` runtime path
   the Makefile references exists in the pinned tarball.
2. **go-smoke** — fast `go build` of both modules for amd64/arm64/mipsle
   (no SDK, catches source breakage quickly). Builds run off a Go module
   cache keyed on the *tarball's* `go.sum` files, and the network-touching
   steps are retried, so a flaky `proxy.golang.org` fetch cannot fail the job.
3. **build-sdk** — the authoritative proof: a real OpenWrt SDK compile of the
   package via `golang-package.mk`, including the nested CLI-module build.

The SDK job is the gate before submitting upstream. See [`PLAN.md`](PLAN.md)
for the full design and the highest-risk item.

## Runtime test scripts

`net/tollgate-wrt/` ships two scripts that the openwrt/packages buildbot runs
in the test environment after installing the package:

- **`test.sh`** — confirms both installed binaries are present and
  executable: the service `/usr/bin/tollgate-wrt` and the CLI
  `/usr/bin/tollgate`. Exit 0 = pass, 1 = fail.
- **`test-version.sh`** — confirms the CLI (`/usr/bin/tollgate`) is present and
  that its version output contains the upstream tag (the Makefile's
  `PKG_SOURCE_VERSION`, i.e. `0.6.0-alpha1`). The CLI exposes the version
  through a cobra `version` subcommand (there is no `--version` flag), so the
  script probes `--version` first and falls back to `version`. The version
  string is injected via the feed's LDFLAGS as
  `cli.Version="v$(PKG_SOURCE_VERSION)"` — LDFLAGS intentionally carry the
  upstream tag, not the apk-legal `PKG_VERSION` (`0.6.0_alpha1`) — so
  `0.6.0-alpha1` always appears. Exit 0 = pass, 1 = fail.

Both scripts are POSIX `sh` and pass `shellcheck -s sh`.

## Submitting to `openwrt/packages` (future)

When this feed is green in CI, the `net/tollgate-wrt/` directory can be lifted
into a PR against `openwrt/packages`. The only change required is the
`golang-package.mk` include path:

```diff
-include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk
+include ../../lang/golang/golang-package.mk
```

Why this swap: as a standalone `src-git` feed, the Go helpers live in the
consumer's installed `packages` feed, so the Makefile anchors at
`$(TOPDIR)/feeds/packages/lang/golang/...`. Inside `openwrt/packages` the file
sits at `net/tollgate-wrt/Makefile`, where the helpers are reached via the
relative `../../lang/golang/golang-package.mk` include. This one-line swap is
the only feed-vs-upstream difference; the module layout and the `Build/Compile`
override (see the comments in the Makefile) are already upstream-compatible.

The package already satisfies the core `openwrt/packages` packaging
requirements, so no further restructuring is needed before the PR:

- `PKG_MAINTAINER` is a real individual — `Felix <felix@tollgate.me>` — so it
  passes `buildbots` `check_pkg_utils`/`check_noreply_email` (a `noreply`
  address or a bare project address would fail upstream CI).
- the init script (the tarball's `packaging/files/etc/init.d/tollgate-wrt`,
  installed to `/etc/init.d/tollgate-wrt`) is procd-compliant
  (`USE_PROCD=1` with `start_service()` and the
  `procd_open_instance`/`procd_set_param`/`procd_close_instance` calls);
- the package declares its config files via the
  `Package/tollgate-wrt/conffiles` block (the plain config files under
  `/etc/tollgate/` — `config.json`, `install.json`, `identities.json` — plus
  `/etc/config/firewall-tollgate`), using file entries (not a bare directory)
  per `openwrt/packages`/arinc9 `BondingShouldBeFree` conffile norm. At
  build time `scripts/ipkg-build` resolves only files present in the package
  data tree (the portal site under `/etc/tollgate/` is runtime-installed),
  while the tarball's `packaging/files/lib/upgrade/keep.d/tollgate` (installed
  to `/lib/upgrade/keep.d/tollgate`) ensures the entire
  `/etc/tollgate/` hierarchy persists through sysupgrade;
- `DEPENDS` pulls only `nodogsplash`, `jq`, and `$(GO_ARCH_DEPENDS)` —
  no `luci` dependency, keeping the runtime footprint minimal.

Follow the
[`openwrt/packages` contributing guide](https://github.com/openwrt/packages/blob/master/CONTRIBUTING.md)
(Signed-off-by, commit-message format) when opening that PR.

## License

`GPL-3.0-only` — matches upstream. The built `tollgate-wrt` package ships
upstream's `LICENSE`.
