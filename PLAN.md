# Plan — OpenWrt feed for `tollgate-module-basic-go`

## Goal

Turn this repo into a clean OpenWrt **`src-git` feed** that builds the
`tollgate-wrt` package from upstream source via `golang-package.mk`, so that:

1. It is usable **today** by firmware builders (`feeds.conf` → this repo).
2. It lifts cleanly into a future PR against [`openwrt/packages`](https://github.com/openwrt/packages),
   achieving the upstream merge that PR [#125](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/125)
   was pursuing.

## Why this approach (lessons from PR #125)

PR #125 tried to restructure upstream's Go source from `src/` → repo root.
That touched ~120 files, conflicted with 14 subsequent merges to `main`, and
was un-reviewable. c03rad0r's June-8 rescue proved the right idea:
**`golang-package.mk` accepts `GO_PKG` pointing at a subdirectory** — no
upstream restructure needed.

By putting the feed glue in **this separate repo**:

- The upstream repo (`tollgate-module-basic-go`) stays **100% untouched** →
  zero rebase collisions forever.
- The eventual `openwrt/packages` PR is a small, reviewable addition of
  `net/tollgate-wrt/{Makefile,files}` — no source shuffle.

## Design

- **One package, two binaries.** A single `Package/tollgate-wrt` installs both
  `/usr/bin/tollgate-wrt` (the service) and `/usr/bin/tollgate` (the CLI). They
  are one functional unit, so there is no dependency-direction problem.
- **Two Go modules, one Makefile.** The service lives in the upstream module
  `github.com/OpenTollGate/tollgate-module-basic-go` (go.mod at `src/`); the CLI
  is a self-contained separate module at `src/cmd/tollgate-cli/`. We override
  `Build/Compile` to: (1) run the default `golang-package.mk` build for the
  service, then (2) a manual `go build` of the CLI from its own module dir,
  reusing the framework's exported cross-compile/toolchain env.
- **Source fetched, not vendored.** `PKG_SOURCE_URL` downloads the upstream
  tarball pinned by `PKG_SOURCE_VERSION` (the upstream git tag); `PKG_HASH`
  pins it. `PKG_BUILD_DIR` points at the tarball's `src/` so
  `golang-package.mk` operates on the module root.
- **Runtime files are NOT vendored** (init.d, uci-defaults, captive-portal
  site, hotplug, keep.d, man pages). They install from the tarball's
  `packaging/files/` tree via `$(PKG_TARBALL_DIR)` — bumping the tag pulls in
  the matching files automatically; there is no files/ tree to keep in sync.
- **Upstream policy compliance** (enforced by CI): no `REPLACES`, no `luci`
  dependency, `GPL-3.0-only`, real `PKG_HASH`.

### Layout

```
feed/
├── net/tollgate-wrt/
│   ├── Makefile          # single package; builds service + CLI; installs
│   │                     # runtime files from the tarball's packaging/files/
│   └── test.sh, test-version.sh   # buildbot runtime-test scripts
├── scripts/
│   └── sync-from-upstream.sh   # re-pin PKG_VERSION/PKG_SOURCE_VERSION/PKG_HASH for a tag
├── .github/workflows/
│   └── validate-feed.yml # lint + PKG_HASH verify + OpenWrt SDK build
├── README.md
├── AGENTS.md
└── PLAN.md               # this file
```

### golang-package.mk include path

- **Standalone feed (this repo):**
  `include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk`
- **When lifted into `openwrt/packages` (future PR):** change that single line to
  `include ../../lang/golang/golang-package.mk`

This one-liner swap is the only feed-vs-upstream difference.

### Key Makefile fields

```makefile
PKG_NAME:=tollgate-wrt
PKG_VERSION:=0.6.0_alpha1           # apk-legal package version (underscore)
PKG_SOURCE_VERSION:=0.6.0-alpha1    # upstream git tag (hyphen): URL + dir names
PKG_RELEASE:=1
PKG_SOURCE:=tollgate-module-basic-go-$(PKG_SOURCE_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/OpenTollGate/tollgate-module-basic-go/tar.gz/v$(PKG_SOURCE_VERSION)?
PKG_HASH:=<sha256>
PKG_BUILD_DIR:=$(BUILD_DIR)/tollgate-module-basic-go-$(PKG_SOURCE_VERSION)/src
PKG_TARBALL_DIR:=$(BUILD_DIR)/tollgate-module-basic-go-$(PKG_SOURCE_VERSION)
GO_PKG:=github.com/OpenTollGate/tollgate-module-basic-go
GO_PKG_BUILD_PKG:=$(GO_PKG)
DEPENDS:=+nodogsplash +jq $(GO_ARCH_DEPENDS)
```

`PKG_VERSION` and `PKG_SOURCE_VERSION` are split because the upstream GitHub
tag is hyphenated (`v0.6.0-alpha1`, immutable) while `apk mkpkg` rejects
hyphens in a package version — it takes `0.6.0_alpha1` → VERSION
`0.6.0_alpha1-r1`. Only `PKG_SOURCE_VERSION` feeds the download URL, the
tag-named build/extract dirs and the LDFLAGS build info; `PKG_TARBALL_DIR` is
the extraction root that the install recipe sources `packaging/files/` from.

## Highest-risk item (gated by CI)

PR #125 never finished proving that `golang-package.mk` works when the module's
`go.mod` lives in a tarball **subdirectory** (`src/`) — plus our extra nested
CLI-module build. The `validate-feed.yml` **OpenWrt SDK build job** is the gate
that proves both compile before any upstream submission.

## Testing pipeline (CI)

`.github/workflows/validate-feed.yml` *is* the testing pipeline. Three jobs:

| Job | Purpose | When it runs |
|---|---|---|
| `validate` | Makefile field lint (no `REPLACES`), `PKG_HASH` vs the live tarball, every referenced `packaging/files/` path exists in the tarball | every push/PR |
| `go-smoke` | plain `go build` of both Go modules for amd64/arm64/mipsle; module cache keyed on the tarball's `go.sum`, network steps retried | every push/PR |
| `build-sdk` | authoritative OpenWrt SDK compile via `golang-package.mk` | main pushes, PRs, tags, weekly, manual dispatch |

Both network-facing jobs are hardened against transient failures: tarball
fetches are retried, and `go-smoke` restores its Go module cache from the
*tarball's* `go.sum` files (the feed repo has no `go.sum` of its own), so
steady-state runs download nothing. Without that cache every run cold-pulled
every module from `proxy.golang.org`, which intermittently aborts a zip
mid-stream (`stream error: ... INTERNAL_ERROR; received from peer`) — that is
what red-lit the mipsle leg of run 34626562337.

`build-sdk` builds a **3-target matrix** so the real TollGate hardware arches
are proven, not just x86-64:

- `x86-64` — host-runnable (amd64)
- `mediatek-filogic` — GL-MT6000 (`aarch64_cortex-a53`)
- `ramips-mt7621` — GL-MT3000 (`mipsel_24kc`)

Each SDK job **uploads** the built `.ipk`/`.apk` as a workflow artifact
(`tollgate-wrt-<target>`) so it can be downloaded for on-router testing
without a local rebuild.

Binary runtime smoke (qemu) is intentionally **not** included, to keep the
pipeline simple. The maintainer-facing proof is the SDK compile itself; runtime
validation happens on real hardware with the uploaded artifacts.

Cost: each `build-sdk` job is slow (~30–60 min, it bootstraps the Go toolchain).
The 3-target matrix runs on main pushes / PRs / tags, so expect ~3× that in CI
minutes on those events (the jobs run in parallel).

SDK image contract (gotcha): since OpenWrt 24.10 the snapshot SDK images
(`-master`/`-SNAPSHOT`) ship an **empty `/builder` plus a `setup.sh`** — the
job must run `./setup.sh` (download + extract the SDK) before feeds/make work.
The job also runs `feeds install -a` (not just `tollgate-wrt`) so the
`golang/host` toolchain and `nodogsplash`/`jq` from the `packages` feed are
available.

## Checklist

- [x] Write `PLAN.md` (this document)
- [x] Wipe unneeded current repo contents
      (`FEED-MANIFEST.conf`, `docs/`, `scripts/generate-*-index.sh`, old workflow)
- [x] Vendor `files/` from upstream `v0.5.0` and pin `PKG_HASH`
- [x] Switch to tarball-install: install runtime files from the pinned
      tarball's `packaging/files/` (`PKG_TARBALL_DIR`), delete the vendored
      `files/` tree, rework the validate job's file checks to run against
      the tarball
- [x] Write `net/tollgate-wrt/Makefile` (single package, both binaries)
- [x] Write `scripts/sync-from-upstream.sh` (idempotent, `shellcheck` clean)
- [x] Write `.github/workflows/validate-feed.yml` (validate + go-smoke + build-sdk)
- [x] Enhance `build-sdk`: run on main pushes, 3-arch matrix (x86-64 +
      mediatek-filogic + ramips-mt7621), upload package artifacts
      (smoke test intentionally omitted to keep it simple)
- [x] Harden CI against transient network failures: retried tarball fetches,
      `go-smoke` module cache keyed on the tarball's `go.sum`, pinned Go 1.25
- [x] Rewrite `README.md` and `AGENTS.md`
- [x] Verify: Makefile lint, hash check, referenced-paths check, `shellcheck`
- [ ] _(future)_ First green `build-sdk` run across all 3 arches
- [ ] _(future)_ Lift `net/tollgate-wrt/` into a PR to `openwrt/packages`
      (swap the `golang-package.mk` include path)
