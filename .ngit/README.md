# Nostr CI for this repo (ngit-ci)

`ngit-ci` runs GitHub-Actions-format workflows through `act` and publishes signed
results to Nostr. It executes **only** the files in `.ngit/act/workflows/` —
`.github/workflows/` is detected but never executed by it. So Nostr CI and
GitHub CI coexist: nothing here changes the GitHub runs.

## What this workflow was verified against

| | |
| --- | --- |
| GitHub source | `https://github.com/FreedomTechFeed/feed` |
| Branch | `main` (the default branch; the coordinator mirrors this one) |
| Verified commit | `24fb821694d3c606871256460f450219441f5e7d` (`ci(feed): namespace SDK cache keys with image version (#7)`) |
| Content under test | `net/tollgate-wrt/Makefile`, the vendored `net/tollgate-wrt/files/` tree (25 files), `scripts/sync-from-upstream.sh`, `.github/workflows/validate-feed.yml` |

An earlier revision of this file was checked against a different repository's
content, so its steps were never proven against the tree the coordinator
actually builds. Every step below was re-executed against **this** branch before
being committed; the raw results are in "Local verification" and the omissions
in "Not covered".

## What runs

`.ngit/act/workflows/feed-test.yml` — one job (`feed-check`),
`timeout-minutes: 15`:

| Step | Why |
| --- | --- |
| Install `shellcheck` | The act job containers are lighter than GitHub runner VMs and do not guarantee shellcheck. The step is a no-op when a usable shellcheck is already on `PATH`, which is what keeps it runnable verbatim outside CI. |
| Collect scripts by shebang | Only real `sh`/`ash`/`bash` scripts are inspected: `scripts/` plus the vendored runtime files under `net/tollgate-wrt/files/` (init.d, uci-defaults, hotplug, usr/bin helpers, first-login-setup). The generated captive-portal site has no shebang and is skipped by construction. |
| `sh -n` on each script | Cheap parse check with the same shell family OpenWrt uses. |
| `shellcheck --severity=error` | Real shell defects. Warnings are deliberately not gated: OpenWrt's `/bin/sh` is busybox ash, which does support `local` (SC3043), and `/etc/rc.common` consumes file-scope `START`/`USE_PROCD`/`EXTRA_*` (SC2034). |
| Makefile lint | Required fields present (`PKG_NAME`, `PKG_VERSION`, `PKG_RELEASE`, `PKG_SOURCE`, `PKG_SOURCE_URL`, `PKG_HASH`, `PKG_MAINTAINER`, `PKG_LICENSE`, `PKG_LICENSE_FILES`, `PKG_BUILD_DIR`, `GO_PKG`, `GO_PKG_BUILD_PKG`), `BuildPackage` evaluated, `golang-package.mk` still included from `$(TOPDIR)/feeds/packages/…` (the src-git feed wiring), upstream policy (no `REPLACES`, no `luci` dependency, `PKG_LICENSE:=GPL-3.0-only`, `PKG_LICENSE_FILES:=LICENSE`, real 64-hex `PKG_HASH`), the version pinning (`PKG_SOURCE`, `PKG_SOURCE_URL`, `PKG_BUILD_DIR` all keyed off `PKG_VERSION` — this repo has no `PKG_VERSION`/`PKG_SOURCE_VERSION` split), and `scripts/sync-from-upstream.sh` present and executable. |
| Referenced `./files/` paths exist | A rename under `net/tollgate-wrt/files/` that the Makefile was not updated for fails here, not at install time on a router. |
| Every vendored file is installed | The converse direction: a file sitting in `files/` that the install recipe never copies is dead weight and a silent divergence between the vendored tree and the package's contents. The captive-portal site is installed recursively, so that one directory is allowed. |
| `PKG_HASH` + tarball layout + vendored drift | Re-downloads the release tarball named by `PKG_VERSION`, compares sha256, asserts it extracts to `tollgate-module-basic-go-$(PKG_VERSION)/` with `src/go.mod` and the nested `src/cmd/tollgate-cli` module (both are what `PKG_BUILD_DIR` and the `Build/Compile` override depend on), and then `diff -r`s the vendored `net/tollgate-wrt/files/` against the tarball's `packaging/files/`. |

Two details that are easy to get wrong and are pinned deliberately:

- The `REPLACES` / `DEPENDS` policy greps use `^[[:space:]]*`. Both live **inside**
  the `define Package/tollgate-wrt` block and are tab-indented there, so an
  anchored `^DEPENDS:=` regex can never match — it is a check that cannot fail.
  The tab-indented predicates here were verified to fire on a poisoned Makefile
  containing `DEPENDS:=… +luci`.
- The vendored-drift `diff -r` encodes `AGENTS.md` golden rule 5 ("`files/` are
  vendored, not generated here; update them only via
  `scripts/sync-from-upstream.sh <tag>`"). This repo's `files/` is currently
  byte-identical to the release tarball's `packaging/files/`, so the gate is
  green on `main`; note that a legitimate feed-local edit to `files/` would make
  it red, which is the intended signal to either re-sync upstream or change
  `AGENTS.md` rule 5.

## Local verification

Driven end to end with the whole file, not a hand-copied command list
(`run-workflow-locally.py` parses the YAML, applies job `env`, and runs every
`run:` step with `bash -e` in a clean worktree of this branch):

```
--- RUN Install shellcheck ---            [step exit=0]   (shellcheck 0.11.0 already on PATH)
--- RUN Collect the shell scripts under test ---
net/tollgate-wrt/files/etc/hotplug.d/iface/95-tollgate-restart
… (9 scripts) …  scripts/sync-from-upstream.sh
Found 9 shell script(s).                  [step exit=0]
--- RUN POSIX syntax check (sh -n) ---     All 9 scripts parse under sh.        [step exit=0]
--- RUN shellcheck (errors only) ---       shellcheck: no errors across 9 scripts. [step exit=0]
--- RUN Lint the package Makefile ---      Makefile lint passed (PKG_VERSION=0.5.0). [step exit=0]
--- RUN Verify every ./files/ path referenced by the Makefile exists ---
11/11 referenced paths exist.             [step exit=0]
--- RUN Verify every vendored file is installed by the recipe ---
All 25 vendored file(s) referenced by the install recipe. [step exit=0]
--- RUN Verify PKG_HASH and the vendored files/ tree against the pinned tarball ---
expected=a547c03cbdfe681e6315e1b6d0e00414daf845a05d20851b92ce55e749edd422
actual  =a547c03cbdfe681e6315e1b6d0e00414daf845a05d20851b92ce55e749edd422
PKG_HASH matches the pinned release.
Tarball layout matches PKG_BUILD_DIR (src/go.mod) and the nested CLI module.
Vendored files/ is identical to packaging/files/ of the v0.5.0 release. [step exit=0]

ALL RUN STEPS PASSED
```

Negative controls (each gate re-run against a deliberately poisoned copy of the
tree under `~/worktrees/.negctl/`, asserting it goes red): 5/5 behaved as
expected — luci dependency injected, a vendored file removed from the
Makefile's view, an uninstalled orphan file added, one vendored file edited by
hand, and `PKG_HASH` altered. In every case the intended step failed with its
own `FAIL:` message and nothing else did.

shellcheck note: CI installs the distro build via `apt-get` (Ubuntu 24.04 ships
0.9.0) and the local run used 0.11.0. Later shellcheck releases add checks, so a
tree clean at 0.11.0 is clean at 0.9.0 at the same `--severity=error`.

## Not covered (deliberately)

- **The OpenWrt SDK build.** `.github/workflows/validate-feed.yml` builds
  `tollgate-wrt` inside `openwrt/sdk:<target>-v25.12.5` via a job-level
  `container:` block that bootstraps the Go toolchain — 30-60 minutes per
  target, and ngit-ci refuses `container:`/`services:` blocks. It cannot run
  here and remains the authoritative gate on GitHub.
- **The `go-smoke` cross-compile** from the GitHub workflow: a three-arch Go
  build of the downloaded upstream source. It needs a Go toolchain plus the full
  upstream tree (`actions/setup-go` + `GOMODCACHE` downloads); it is the one
  GitHub job that would be cheap to add later, but this pass pins `PKG_HASH`
  and the tarball layout instead and leaves the toolchain provisioning to
  GitHub.
- **Executing anything against a router**: init-script behaviour, NoDogSplash
  integration, captive-portal flows, `uci-defaults` semantics.
- **`PKG_HASH`-vs-tarball for a version that is not `PKG_VERSION`** — N/A; this
  branch has a single version field.
- **Feed index generation** (`make package/index`) needs the SDK — out of scope.
- **Repo-wide `shellcheck`** over the whole GitHub workflow: not gated, the act
  container may not carry a bash new enough for every helper.

Observed but not gated (reported, not silenced): `net/tollgate-wrt/Makefile`
carries `# SPDX-License-Identifier: GPL-2.0-only` at the top while
`PKG_LICENSE:=GPL-3.0-only` below. The license gate asserts the field (which is
what the package manager and upstream policy read); the SPDX header mismatch is
a repo-local inconsistency for a human to resolve.

## Where this file may live

`.ngit/` sits on the branch `ci/ngit-workflows`, **not** on `main`. That is
deliberate: the GitHub→ngit bridge mirrors with a plain `git push` (no
`--force`), so a file that exists only on the ngit mirror's default branch would
make the bridge's next push non-fast-forward and break the mirror. A dedicated
ref keeps the mirrored content identical to GitHub and leaves zero upstream diff,
and the coordinator runs the workflow when that ref is pushed or when a manual
trigger (kind `9840`) targets it.

## Triggers

`on: push` and `on: pull_request` — no `schedule` (ngit-ci has no timer), no
`workflow_dispatch` dependency, no secrets, no `GITHUB_TOKEN`. Each run is at
most 15 minutes; the coordinator's own ceiling is 30.

## Authorization: this repo runs `request-required`

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
nak req -k 9841 -a <coordinator-hex> -l 20 wss://relay.ngit.dev   # per-job results
nak req -k 9842 -a <coordinator-hex> -l 5  wss://relay.ngit.dev   # workflow conclusion
nak req -k 39842 -a <coordinator-hex> -l 20 wss://relay.ngit.dev  # progress
```

- **9841** — job result, `content` carries the log tail.
- **9842** — workflow result/conclusion.
- **39842** — workflow progress.

Older `ngit` builds on this fleet have no `ci` subcommand, so read the relays
directly rather than expecting `ngit ci status`.

## If a step fails inside the act container

The act images are lighter than GitHub runner VMs: treat a failure as an
environment gap until proven otherwise (missing tool or incomplete base image),
not automatically as a code failure. This workflow installs `shellcheck` itself
for exactly that reason, and every step after that needs nothing but `curl`,
`tar`, `diff` and the base shell.
