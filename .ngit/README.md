# Nostr CI for this repo (ngit-ci)

`ngit-ci` runs GitHub-Actions-format workflows through `act` and publishes signed
results to Nostr. It executes **only** the files in `.ngit/act/workflows/` —
`.github/workflows/` is detected but never executed by it. So Nostr CI and
GitHub CI coexist: nothing here changes the GitHub runs.

## What runs

`.ngit/act/workflows/feed-test.yml` — one job, `timeout-minutes: 15`:

| Step | Why |
| --- | --- |
| Collect scripts by shebang | Only real `sh`/`ash`/`bash` scripts are inspected; the generated captive-portal site under `files/` is skipped by construction. |
| `sh -n` on each script | Cheap parse check with the same shell family OpenWrt uses. |
| `shellcheck --severity=error` | Real shell defects. Warnings are deliberately not gated: OpenWrt's `/bin/sh` is busybox ash, which does support `local` (SC3043), and `/etc/rc.common` consumes file-scope `START`/`USE_PROCD`/`EXTRA_*` (SC2034). |
| Makefile lint | `PKG_NAME`/`PKG_VERSION`/`PKG_RELEASE`/`PKG_SOURCE_URL`/`PKG_HASH`/`PKG_MAINTAINER`/`PKG_LICENSE`/`PKG_BUILD_DIR`/`GO_PKG*` present, `BuildPackage` evaluated, `golang-package.mk` still included from the packages feed (src-git wiring), and upstream-policy rules: no `REPLACES`, `PKG_LICENSE:=GPL-3.0-only`, real 64-hex `PKG_HASH`. |
| Referenced `./files/` paths exist | A rename under `net/tollgate-wrt/files/` that the Makefile was not updated for fails here, not at install time on a router. |
| `PKG_HASH` vs the pinned tarball | Re-downloads the release tarball named by `PKG_VERSION` and compares sha256, so a `PKG_VERSION` bump without a `PKG_HASH` update fails. |

Every step was executed by hand in a clean worktree of this branch before being
committed. Local result: 9 shell scripts parsed, shellcheck clean at
`--severity=error`, Makefile lint passed, all 11 referenced `./files/` paths
present, and `PKG_HASH` matched the v0.5.0 tarball.

## Not covered (deliberately)

- **The OpenWrt SDK build.** `.github/workflows/validate-feed.yml` builds
  `tollgate-wrt` inside `openwrt/sdk:<target>-v25.12.5` via a job-level
  `container:` block that bootstraps the Go toolchain — 30-60 minutes per
  target, and ngit-ci refuses `container:`/`services:` blocks. It cannot run
  here and remains the authoritative gate on GitHub.
- **The `go-smoke` cross-compile** from the GitHub workflow (needs a Go
  toolchain installed over the network and a full upstream source download).
  Kept on GitHub rather than duplicated here.
- **No test harness exists to run.** This branch has no `tests/` directory, no
  `test.sh`, and the only `Makefile` targets are OpenWrt package macros
  (`Build/Prepare`, `Build/Compile`, `Package/...`) — there is nothing else to
  invoke, so nothing else is claimed.
- **Vendored `files/` vs upstream drift.** `net/tollgate-wrt/files/` is a
  vendored copy synced by `scripts/sync-from-upstream.sh`; a diff against the
  tarball's `packaging/files/` is not gated (the vendored copy is allowed to
  carry feed-local edits).
- **Anything that needs a router**: init-script behaviour, NoDogSplash
  integration, captive-portal flows.

## Triggers

`on: push` and `on: pull_request` — no `schedule` (ngit-ci has no timer), no
`workflow_dispatch` dependency. Each run is at most 15 minutes; the coordinator's
own ceiling is 30.

## Authorization: this coordinator runs `request-required`

Ordinary `push`/`pull_request` runs do **not** start on their own. A maintainer
must first publish a **standing Service Request** (kind `9843`) for this repo:

```jsonc
{ "kind": 9843, "content": "",
  "tags": [["a","30617:<maintainer-pubkey>:<repo-id>"],
           ["p","<coordinator-pubkey>"]] }
```

Until that exists the coordinator logs `Skipping push trigger until an authorized
Service Request is observed`. A one-shot manual trigger (kind `9840`) bypasses
the gate and is useful for a first smoke run. The workflow result quotes the
Service Request it ran under in its `q` tag.

## Reading the results

```bash
ngit ci status <commit|pr>          # summary for a commit or PR
nak req -k 9841 -a <coordinator-hex> -l 20 wss://relay.ngit.dev   # per-job results
nak req -k 9842 -a <coordinator-hex> -l 5  wss://relay.ngit.dev   # workflow conclusion
nak req -k 39842 -a <coordinator-hex> -l 20 wss://relay.ngit.dev  # progress
```

- **9841** — job result, `content` carries the log tail.
- **9842** — workflow result/conclusion.
- **39842** — workflow progress.

## If a step fails inside the act container

The act images are lighter than GitHub runner VMs: treat a failure as an
environment gap until proven otherwise (missing tool or incomplete base image),
not automatically as a code failure. This workflow installs `shellcheck` itself
for exactly that reason.
