# Plan — OpenWrt feed for `tollgate-module-basic-go`

## Goal

Turn this repo into a clean OpenWrt **`src-git` feed** that builds the
`tollgate-wrt` package from upstream source via `golang-package.mk`, so that:

1. It is usable **today** by firmware builders (`feeds.conf` → this repo).
2. The `net/tollgate-wrt/` directory stays in the shape a future
   `openwrt/packages` submission would take — one directory, one substituted
   include line, no restructuring.

(Opening that upstream PR is currently an explicit operator **no**; the shape is
maintained so the option stays open, not because a PR is planned.)

## Why this approach (lessons from PR #125)

PR #125 tried to restructure upstream's Go source from `src/` → repo root.
That touched ~120 files, conflicted with 14 subsequent merges to `main`, and
was un-reviewable. `golang-package.mk` accepts `GO_PKG` pointing at a
subdirectory — the module root simply has to be `PKG_BUILD_DIR`, because that
is where the framework looks for `go.mod` (`lang/golang/golang-build.sh`). So
no upstream restructure is needed, and by keeping the feed glue in this
separate repo the eventual upstream addition is small and reviewable.

## Version identity (the part that silently breaks packages)

Two spellings of one release, normalised per package manager:

| | value | rule |
|---|---|---|
| `PKG_SOURCE_VERSION` | `0.6.0-alpha1` | upstream tag body (`v0.6.0-alpha1`) |
| `PKG_VERSION` (apk) | `0.6.0_alpha1` | apk allows `-` only as `-r<digits>` |
| `PKG_VERSION` (opkg) | `0.6.0~alpha1` | opkg ranks `_alpha1` above the bare release |
| `PKG_RELEASE` | `1` | owns the revision; never write `-rN` in `PKG_VERSION` |

`scripts/check-version-strings.sh` is the offline gate for all of it (plus
metadata, SPDX-vs-`PKG_LICENSE`, procd init, and install steps referencing
missing files). `scripts/sync-from-upstream.sh <tag>` rewrites the pins for a
new release.

The version is injected into the service binary with the same ldflags symbol
upstream's CI uses. Neither binary supports `--version` (see README), so
`test-version.sh` supplies the CI harness' version check.

## Design

- **One package, two binaries.** A single `Package/tollgate-wrt` installs both
  `/usr/bin/tollgate-wrt` (the service) and `/usr/bin/tollgate` (the CLI).
- **Two Go modules, one Makefile.** The service is the module at
  `src/`; the CLI is a self-contained module at `src/cmd/tollgate-cli/` that no
  `GO_PKG_BUILD_PKG` can reach (`go install` cannot cross a module boundary).
  `Build/Compile` builds the service through the framework helper, then the CLI
  from its own module dir with the framework's exported cross-compile env.
- **Source fetched, never vendored.** `PKG_SOURCE_URL` is the codeload tarball
  for a release tag; `PKG_HASH` pins its sha256. No `latest`, no branch heads.
- **`PKG_BUILD_DIR` = the tarball's `src/`** so `golang-package.mk` operates on
  the module root and `src/go.mod`'s `replace ./sibling` directives resolve.
- **Runtime `files/` ARE vendored**, verbatim from the pinned tag's
  `packaging/files/` (60 files), re-synced by `scripts/sync-from-upstream.sh`.
  The compiled captive-portal SPA bundles live in `portal-assets/` instead —
  they come from a separate npm build upstream injects as a CI artifact (see
  `portal-assets/README.md`).
- **Upstream policy compliance:** no `REPLACES`, no `luci` dependency,
  `GPL-3.0-only` matching upstream's LICENSE, real `PKG_HASH`.

### Layout

```
feed/
├── net/tollgate-wrt/
│   ├── Makefile                 # single package; builds service + CLI
│   ├── test-version.sh          # CI version check override
│   ├── files/                   # verbatim tag packaging/files/ (init.d, uci-defaults, …)
│   └── portal-assets/assets/    # compiled captive-portal SPA bundles
├── scripts/
│   ├── sync-from-upstream.sh    # re-pin version/hash + re-vendor files/
│   └── check-version-strings.sh # offline pre-build gate
├── .github/workflows/
│   └── validate-feed.yml        # lint + hash verify (+ SDK build)
├── README.md
├── AGENTS.md
└── PLAN.md                      # this file
```

### golang-package.mk include path

- **Standalone feed (this repo):**
  `include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk`
- **Inside `openwrt/packages` (or a fork of it):**
  `include ../../lang/golang/golang-package.mk`

This one line is the only difference between the two homes; it is the only
edit needed when the directory is lifted.

### Key Makefile fields

```makefile
PKG_NAME:=tollgate-wrt
PKG_SOURCE_VERSION:=0.6.0-alpha1
PKG_SOURCE_COMMIT:=414650310b829ae6715fcffbc473e62a25655ed6
ifeq ($(CONFIG_USE_APK),y)
PKG_VERSION:=0.6.0_alpha1
else
PKG_VERSION:=0.6.0~alpha1
endif
PKG_RELEASE:=1
PKG_SOURCE_URL:=https://codeload.github.com/OpenTollGate/tollgate-module-basic-go/tar.gz/v$(PKG_SOURCE_VERSION)?
PKG_HASH:=c0ca1b37cbccde8e46de8e42287185d322c648bb10ad317b3e496a136a0e35f7
PKG_MAINTAINER:=TollGate <tollgate@tollgate.me>
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_BUILD_DIR:=$(BUILD_DIR)/tollgate-module-basic-go-$(PKG_SOURCE_VERSION)/src
GO_PKG:=github.com/OpenTollGate/tollgate-module-basic-go
GO_PKG_BUILD_PKG:=$(GO_PKG)
```

## Highest-risk item (proven, not assumed)

PR #125 never finished proving that `golang-package.mk` works when the module's
`go.mod` lives in a tarball **subdirectory** (`src/`) — plus the extra nested
CLI-module build. Both were proven with a real SDK compile of this package on
`mediatek-filogic` (`aarch64_cortex-a53`): see the run evidence recorded on the
kanban card (raw `feeds update/install`, `make .../check`, `make .../compile`,
the produced package filename, and the binary's version).

## Testing pipeline

`scripts/check-version-strings.sh` is the fast, deterministic, offline gate
(23 checks) and runs on every push. `.github/workflows/validate-feed.yml` adds
lint + `PKG_HASH` verification against the live tarball. The authoritative
proof is a real SDK compile:

```sh
# inside a pinned openwrt/sdk:<target>-v25.12.5 container
./scripts/feeds update packages tollgate
./scripts/feeds install -a -p tollgate
make defconfig
make package/feeds/tollgate/tollgate-wrt/download V=s
make package/feeds/tollgate/tollgate-wrt/check V=s
make package/feeds/tollgate/tollgate-wrt/compile V=s
```

Notes learned the hard way:

- Pin **release** SDK images (`<target>-v25.12.5`), never `:latest`/`-master`;
  moving tags rot silently.
- Do not bind-mount `staging_dir`/`build_dir` over the image's own: the image's
  prebuilt staging tree carries a host-gcc symlink that only `make defconfig`
  repairs in-container.
- `make package/.../check` is a light gate (download + hash); `compile` is what
  actually exercises `golang-package.mk`.
- `nodogsplash` is not in the 25.12 packages feed (only `openwrt/packages@master`
  has it), so the `DEPENDS` line cannot be satisfied by a stock 25.12 build —
  see README. Compilation is unaffected.

## Checklist

- [x] Write `PLAN.md` (this document)
- [x] Wipe unneeded repo contents (old manifest/index scripts/workflow)
- [x] Vendor `files/` verbatim from the pinned tag and pin `PKG_HASH`
- [x] Version identity: per-manager spellings, proven with the real tools
- [x] `Build/Prepare` handles the `src/` module root (no upstream restructure)
- [x] `test-version.sh` (neither binary implements `--version`)
- [x] `scripts/check-version-strings.sh` offline gate + RED/GREEN demo
- [x] `scripts/sync-from-upstream.sh` re-pins version/hash and re-vendors files/
- [x] Prove the build on a pinned 25.12 SDK (`mediatek-filogic`) and record raw output
- [x] Rewrite `README.md` (honest supported matrix) and this plan
- [x] Runtime feed: index generate + sign + atomic publish (`scripts/feed-publish.sh`,
      `scripts/feed-verify.sh`, `scripts/feed-manifest.sh`, `scripts/feed-keygen.sh`,
      `scripts/get-host-apk-tools.sh`) — see `docs/feed-index-publishing.md`
- [x] Trust gate on a real 25.12 rootfs: unsigned index fails, signed succeeds,
      missing/wrong key fails, `apk add` installs (`tests/apk-index-trust-test.sh`, 5/5)
- [x] Publish refusal rules: manifest hash mismatch, missing artifact, unversioned
      name, re-cut, private key in the keys dir, unsigned opt-in, key rotation,
      retention, dry-run (`tests/feed-publish-test.sh`, 12/12)
- [x] opkg `Packages.sig` signing with usign, proven on a real 24.10.8 rootfs —
      and the memo corrected: release images DO enable `check_signature`
      (`tests/opkg-index-test.sh`, 3/3)
- [ ] Run the same compile on the remaining matrix targets (x86-64, ramips-mt7621)
- [ ] Publish the feed site itself (FEED-SERVE-PROVE: Caddy + ansible, headers)
- [ ] Router-hardware install of the real package from the feed (RC-ACCEPTANCE)
- [ ] _(future)_ exercise the built package on router hardware
- [ ] _(future, operator-gated)_ lift `net/tollgate-wrt/` into `openwrt/packages`
