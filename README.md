# TollGate OpenWrt Feed

An OpenWrt package feed that builds **`tollgate-wrt`** from the upstream
[`OpenTollGate/tollgate-module-basic-go`](https://github.com/OpenTollGate/tollgate-module-basic-go)
release tarball using OpenWrt's `golang-package.mk`.

TollGate turns an OpenWrt router into a Cashu-powered payment gateway for
internet access. The package installs both binaries — the `tollgate-wrt`
service and the `tollgate` CLI — plus its init script, UCI defaults,
captive-portal site, nftables snippets and hotplug hooks.

Upstream is **not modified**: it is downloaded (by sha256-pinned tarball),
built, and packaged entirely from the release source.

## Supported matrix (honest version)

| OpenWrt | Package manager | Status |
|---|---|---|
| **25.12** (and 25.12.x SDK images) | apk | **supported** — built and verified here |
| **master** (snapshot) | apk | **supported** — the packages feed ships Go 1.27 |
| 24.10 | opkg | **not supported** — feed ships Go 1.23.12, module needs go >= 1.25 |
| 23.05 | opkg | **not supported** — feed ships Go 1.21, module needs go >= 1.25 |

The Go floor is upstream's: `src/go.mod` in the pinned release says
`go 1.25.0`, and OpenWrt's `golang-package.mk` refuses to build a module whose
`go` directive is newer than the toolchain it ships. Verified directly:

- 25.12 packages feed → `lang/golang/golang-values.mk`: `GO_DEFAULT_VERSION:=1.26`
- master packages feed → `GO_DEFAULT_VERSION:=1.27`
- 24.10 packages feed → `lang/golang/golang/Makefile`: `GO_VERSION_MAJOR_MINOR:=1.23` (patch 12)
- 23.05 packages feed → `GO_VERSION_MAJOR_MINOR:=1.21`

The `PKG_VERSION` string is spelled per package manager (`0.6.0_alpha1` on
apk, `0.6.0~alpha1` on opkg), so a future 24.10-capable toolchain would not
need a Makefile change — but until OpenWrt's 24.10 feed ships Go >= 1.25,
**do not claim 24.10 support** and do not expect an opkg artifact from CI.

Two further facts about the target line, both verified on 2026-09-13:

- `nodogsplash` is **not** in the 25.12 packages feed. The 25.12 feed pinned by
  the SDK (`git.openwrt.org/feed/packages.git^5caa62e0`) has no
  `net/nodogsplash`, and neither does the `openwrt-25.12` branch tree; only
  `openwrt/packages@master` carries `net/nodogsplash` (and `net/opennds`).
  `DEPENDS:=+nodogsplash` therefore cannot be satisfied by a stock 25.12 build
  — a build that needs the package must supply NoDogSplash from another feed
  or vendor it. This does not affect compilation of this package.
- `PKG_SOURCE_VERSION` is pinned to an **existing** upstream tag. The next
  release tag (`v0.6.0-alpha2`) was still being prepared upstream at the time
  of writing, so the feed is proven against `v0.6.0-alpha1` — see
  [Version identity](#version-identity) for the one-line bump.

## Using the feed

```sh
echo "src-git tollgate https://github.com/FreedomTechFeed/feed.git" >> feeds.conf
./scripts/feeds update tollgate
./scripts/feeds install -a -p tollgate
```

Then enable **Network → Captive Portals → tollgate-wrt** in `make menuconfig`,
and build:

```sh
make package/feeds/tollgate/tollgate-wrt/compile V=s
```

> `golang-package.mk` (the Go build helpers) comes from the standard
> `packages` feed, so keep that feed enabled. `jq` comes from there too.
> `nodogsplash` is listed as a runtime dependency — see the matrix note above.

## Runtime feed (installing on a router)

The `src-git` feed above is for **building firmware**. A router that installs
the package with `apk`/`opkg` needs the *runtime* feed: a signed index plus
versioned package files, served over HTTPS. It lives in a separate tree with
its own keys and channel paths:

```
<tree>/keys/<name>.pem
<tree>/<channel>/<line>/<arch>/packages.adb + <pkg>-<ver>.apk
```

`scripts/feed-publish.sh` generates, **signs** and atomically publishes it —
an unsigned apk index makes `apk update` fail with `UNTRUSTED signature` for
every tester, so signing is enforced by the script rather than documented as a
step. `scripts/feed-verify.sh` re-fetches the published index and hash-checks
every package it lists.

Full design, the measured facts (including one correction to the consultant
memo about opkg signature checking), the hand-runnable commands and the tests:
[`docs/feed-index-publishing.md`](docs/feed-index-publishing.md).

## Version identity

Two strings, one release, both proven with the real comparison tools rather
than asserted:

| | value | why |
|---|---|---|
| `PKG_SOURCE_VERSION` | `0.6.0-alpha1` | the body of the upstream tag `v0.6.0-alpha1` |
| `PKG_VERSION` (apk) | `0.6.0_alpha1` | apk's grammar (`digit{.digit}*[_suf#]*[-r#]`) allows `-` **only** as `-r<digits>`; `0.6.0-alpha1-r1` is `TOKEN_INVALID` and would not install |
| `PKG_VERSION` (opkg) | `0.6.0~alpha1` | opkg splits at the last hyphen and ranks `_alpha1` **above** the bare release, so the apk spelling would never be seen as upgradeable to `0.6.0` |

`PKG_RELEASE` owns the revision: never write `-rN` into `PKG_VERSION`, and bump
`PKG_RELEASE` (not the version) when re-cutting identical content.

Two consequences worth knowing (both measured, not guessed):

- The package the build produces is named and versioned with the manager's own
  spelling — `tollgate-wrt-0.6.0_alpha1-r1.apk` on the 25.12 SDK, with
  `version: 0.6.0_alpha1-r1` in its control metadata.
- The *feed index* that `./scripts/feeds` generates is written before any
  `.config` exists, so `CONFIG_USE_APK` is unset at that point and the index
  records the opkg spelling (`Version: 0.6.0~alpha1-r1`). That is cosmetic: it
  is what `menuconfig` displays, not what gets built.

Both spellings are checked offline by
[`scripts/check-version-strings.sh`](scripts/check-version-strings.sh), which
also fails on `-alphaN` markers, a hand-written `-rN`, an SPDX header that
disagrees with `PKG_LICENSE`, missing metadata, an init script that is not
procd-based, and install steps that reference files which are not vendored:

```sh
sh scripts/check-version-strings.sh          # offline, 23 checks
sh scripts/check-version-strings.sh --hash   # ... also re-verifies PKG_HASH + files/
```

### Version injection into the binaries

`GO_PKG_LDFLAGS_X` sets `.../src/cli.Version`, `.../src/cli.GitCommit` and
`.../src/cli.BuildTime` — the same symbol upstream's CI sets, so the running
service reports the packaged version through its socket API.

Be aware of what upstream does *not* support (measured against the pinned
tarball, not assumed):

- `tollgate-wrt --version` is not a thing. The service has no flag parser; any
  argument is ignored and the daemon starts.
- `tollgate --version` exits 1 with `unknown flag: --version` (the cobra root
  command declares no `Version`), and `tollgate version` needs the running
  service's Unix socket.
- Only the service binary links `src/cli`; the CLI is a separate module that
  does not, so no `-X` flag can put a version string in it.

That is why this directory ships
[`test-version.sh`](net/tollgate-wrt/test-version.sh): the openwrt/packages CI
harness runs it *instead of* its generic `--version` probe, and it asserts the
injected version directly in the compiled service binary.

## How one package builds two binaries

The upstream source has **two Go modules**:

- the service, main module at `src/` (`github.com/OpenTollGate/tollgate-module-basic-go`),
- the CLI, a self-contained module at `src/cmd/tollgate-cli/` (`module tollgate-cli`).

`golang-package.mk` builds one module per Makefile, and `go install` cannot
cross a module boundary, so no `GO_PKG_BUILD_PKG` value can reach the CLI.
`Build/Compile` therefore runs the framework helper for the service and then
builds the CLI from its own module directory with the framework's exported
cross-compile environment (`$(GO_PKG_VARS)`).

The module root matters: `golang-package.mk` only takes the Go *module* path
when `$PKG_BUILD_DIR/go.mod` exists (`lang/golang/golang-build.sh`), so
`PKG_BUILD_DIR` points at the tarball's `src/` subdirectory. That is also what
makes the `replace ./sibling` directives inside `src/go.mod` resolve. Upstream
PR [#125](https://github.com/OpenTollGate/tollgate-module-basic-go/pull/125)
tried moving `src/` to the repository root instead and could not be rebased —
this feed exists so that never has to happen again.

## Layout

```
net/tollgate-wrt/
├── Makefile                        # the package recipe
├── test-version.sh                 # CI version check override (no --version upstream)
├── files/                          # verbatim copy of the tag's packaging/files/
└── portal-assets/assets/           # compiled captive-portal SPA bundles (see its README)
scripts/
├── check-version-strings.sh        # offline pre-build gate
└── sync-from-upstream.sh           # re-pin version/hash, re-vendor files/
```

### Why `files/` and `portal-assets/` are separate

`files/` is re-synced byte-for-byte from the pinned tag's `packaging/files/`, so
`diff -r net/tollgate-wrt/files <tarball>/packaging/files` is empty and a future
upstream submission is a copy of one directory, not a merge.

`portal-assets/` is additive. The captive-portal SPA is built with `npm` from
the separate `tollgate-captive-portal-site` repository, and upstream injects
the compiled bundles into its release artifacts as a CI artifact. An OpenWrt
build has no npm and no business reaching that repository, so the bundles are
vendored here; `scripts/sync-from-upstream.sh` cross-checks them against each
release's `asset-manifest.json` and warns when a release expects different
ones.

## Syncing a new upstream release

```sh
scripts/sync-from-upstream.sh v0.6.0-alpha2
```

That downloads the tag's tarball, recomputes `PKG_HASH`, resolves the tag's
commit, rewrites `PKG_SOURCE_VERSION` / `PKG_SOURCE_COMMIT` / both
`PKG_VERSION` spellings, re-vendors `packaging/files/`, and re-checks the
portal assets. Then:

```sh
sh scripts/check-version-strings.sh --hash    # offline checks + hash + files/ diff
```

and commit. Reviewing the diff should show: the four pin lines, the re-vendored
`files/`, and nothing else (unless the portal bundles changed, which the script
reports).

## Validation

- `scripts/check-version-strings.sh` — offline, deterministic, 23 checks.
- `make package/feeds/tollgate/tollgate-wrt/check` / `compile` inside a pinned
  OpenWrt SDK. The build is the only thing that proves `golang-package.mk` is
  happy with the `src/` module root and the second module.
- `.github/workflows/validate-feed.yml` runs lint + hash verification; the SDK
  job is the authoritative gate.

Nothing in this repository has been exercised on router hardware. Items that
were only compiled — not installed and run on a router — are untested.

## Submitting to `openwrt/packages` (not currently planned)

The `net/tollgate-wrt/` directory is kept in the shape an upstream submission
would take. The only difference between this repo's copy and the copy that
lives in the `FreedomTechFeed/packages` fork is one line:

```diff
-include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk
+include ../../lang/golang/golang-package.mk
```

A standalone feed has no `../../lang/golang/` next to the package directory
(its golang helpers live in the installed `packages` feed), while a checkout of
`openwrt/packages` does. Everything else — metadata, `PKG_HASH` pinning, the
`Build/Prepare` glue, `files/` — is identical, so lifting the directory is a
copy plus that one substitution.

Opening an upstream PR is currently **explicitly out of scope** for this
project (operator directive), so this section is kept only as a statement of
shape.

## License

`GPL-3.0-only`, matching upstream's `LICENSE`.
