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
net/tollgate-wrt/files/     # vendored runtime files (init.d, uci-defaults, captive-portal site, …)
scripts/sync-from-upstream.sh
scripts/index-feed.sh       # feed indexer (per-arch APKINDEX.tar.gz / Packages.gz)
scripts/generate-apk-index.sh
scripts/generate-packages-index.sh
scripts/target-to-arch.sh   # SDK target → arch tuple map (single source of truth)
scripts/artifact-arch.sh    # read the arch tuple embedded in a .apk/.ipk
tests/test-index-feed.sh    # synthetic index-pipeline test (sh tests/…)
.github/workflows/validate-feed.yml   # build gate (lint, go-smoke, build-sdk)
.github/workflows/build-feed.yml      # publish: tag → release → indices → gh-pages
docs/feed-index.md          # the publish pipeline + feed consumption
PLAN.md                     # design + checklist (keep the checklist current)
```

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
5. **`files/` are vendored**, not generated here. Update them only via
   `scripts/sync-from-upstream.sh <tag>`.

## Releasing a new version

```sh
scripts/sync-from-upstream.sh v0.5.1   # updates PKG_VERSION, PKG_HASH, files/
```

Then verify the CI `go-smoke` + `build-sdk` jobs pass before merging.
**Merge first, tag second**: pushing `vX.Y.Z` after the merge makes
`build-feed.yml` bridge the tag run's SDK artifacts into a GitHub release
(tuple-suffixed assets), generate per-arch-tuple indices, and deploy them
to gh-pages — the consumer feed. Full procedure + rationale:
[`docs/feed-index.md`](docs/feed-index.md).

## Verification

- Lint + hash + files check + Go smoke: the `validate` and `go-smoke` jobs run
  on every push/PR. They are fast and deterministic.
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
