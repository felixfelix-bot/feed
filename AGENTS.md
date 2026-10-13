# AGENTS.md — TollGate OpenWrt Feed

Guidance for AI agents (and humans) working in this repo.

## What this repo is

An OpenWrt **`src-git` feed** with two independent packages:

| Package | Language | Build system | Source | Status |
|---|---|---|---|---|
| `tollgate-wrt` | Go | `golang-package.mk` | [OpenTollGate/tollgate-module-basic-go](https://github.com/OpenTollGate/tollgate-module-basic-go) | ready |
| `mptcp-bonding` | shell | pure files (no compile) | [c03rad0r/tg-mptcp-server](https://github.com/c03rad0r/tg-mptcp-server) | ready |

Each package lives in its own `net/<name>/` directory and builds independently.

## Layout

```
net/tollgate-wrt/Makefile   # Go: Cashu-powered WiFi payment gateway recipe
net/tollgate-wrt/files/     # vendored runtime files
net/mptcp-bonding/Makefile  # shell: MPTCP multi-WAN bonding client (pure files)
net/mptcp-bonding/files/    # init.d, UCI config, sysctl, setup-bond helper
scripts/sync-from-upstream.sh
.github/workflows/validate-feed.yml
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

## Package-specific notes

### tollgate-wrt (Go)

Two binaries in two separate Go modules. The service is the main module at
`src/`; the CLI is a self-contained module at `src/cmd/tollgate-cli/`. The
`Build/Compile` override builds both. Release: `scripts/sync-from-upstream.sh v0.5.1`.

### mptcp-bonding (shell)

Pure-files package (no compilation): a procd init script, a UCI schema, an
MPTCP kernel sysctl config, and a `setup-bond.sh` helper. Depends on
`shadowsocks-libev-ss-redir`, `ip-full`, and `kmod-sched`. The matching server
is deployed by Ansible from `c03rad0r/tg-mptcp-server`.

## Releasing a new version

```sh
scripts/sync-from-upstream.sh v0.5.1   # updates PKG_VERSION, PKG_HASH, files/
```

Then verify the CI `go-smoke` + `build-sdk` jobs pass before merging.

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

The `validate` job only lints `net/tollgate-wrt` directly, so adding a new
sibling package under `net/` does not require workflow changes unless that
package needs its own compile/hash checks.

## Submitting upstream (future)

When CI is green, lift `net/tollgate-wrt/` into a PR to `openwrt/packages`.
Swap the one include line (`$(TOPDIR)/feeds/packages/lang/golang/...` →
`../../lang/golang/...`). See README and PLAN.md.
