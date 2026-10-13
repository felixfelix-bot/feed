# AGENTS.md — TollGate OpenWrt Feed

Guidance for AI agents (and humans) working in this repo.

## What this repo is

An OpenWrt **`src-git` feed** that builds the `tollgate-wrt` package from the
upstream [`tollgate-module-basic-go`](https://github.com/OpenTollGate/tollgate-module-basic-go)
source tarball via `golang-package.mk`. The end goal is to get `tollgate-wrt`
merged into [`openwrt/packages`](https://github.com/openwrt/packages).

## Layout

```
net/tollgate-wrt/Makefile   # the package recipe (single package, two binaries)
scripts/sync-from-upstream.sh
.github/workflows/validate-feed.yml
PLAN.md                     # design + checklist (keep the checklist current)
```

The runtime files (init.d, uci-defaults, nftables.d, hotplug.d, man pages,
captive-portal site, usr/bin helpers, keep.d) are NOT in this repo — the
Makefile installs them from the pinned source tarball's `packaging/files/`
(`$(PKG_TARBALL_DIR)` in the Makefile).

## Golden rules

1. **Never modify the upstream repo.** This feed downloads the source tarball
   and builds it as-is. If something needs to change in the Go code, change it
   *upstream*, tag a release, then re-sync here.
2. **One package, both binaries.** `tollgate-wrt` installs `/usr/bin/tollgate-wrt`
   *and* `/usr/bin/tollgate` together. Do not split into two packages — they're
   one functional unit.
3. **Upstream policy compliance** (enforced by CI): no `REPLACES`, no `luci`
   dependency, `PKG_LICENSE:=GPL-3.0-only`, real `PKG_HASH` (never `skip`).
4. **The two binaries live in two separate Go modules.** The service is the
   main module at `src/`; the CLI is a self-contained module at
   `src/cmd/tollgate-cli/`. The `Build/Compile` override handles both. See the
   comments in the Makefile.
5. **Runtime files are not vendored.** They install from the pinned source
   tarball's `packaging/files/` via `$(PKG_TARBALL_DIR)` in the Makefile.
   Never copy runtime files into `net/tollgate-wrt/` — bump the tag instead
   (`scripts/sync-from-upstream.sh <tag>`).

## Releasing a new version

```sh
scripts/sync-from-upstream.sh v0.6.0-alpha1   # updates PKG_VERSION, PKG_SOURCE_VERSION, PKG_HASH
```

Then verify the CI `go-smoke` + `build-sdk` jobs pass before merging.

## Verification

- Lint + hash + tarball file checks + Go smoke: the `validate` and `go-smoke`
  jobs run on every push/PR. They are fast and deterministic.
- The `build-sdk` job (OpenWrt SDK compile) is the authoritative gate. It runs
  on PRs, tags, weekly, and manually.

## Highest-risk detail

`golang-package.mk` building a module whose `go.mod` lives in a tarball
**subdirectory** (`src/`), plus the manual nested CLI-module build. This is the
single most fragile part; the `build-sdk` CI job exists specifically to prove
it. If `build-sdk` fails, focus there first.

## Submitting upstream (future)

When CI is green, lift `net/tollgate-wrt/` into a PR to `openwrt/packages`.
Swap the one include line (`$(TOPDIR)/feeds/packages/lang/golang/...` →
`../../lang/golang/...`). See README and PLAN.md.
