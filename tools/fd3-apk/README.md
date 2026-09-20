# FD3 — packaging a *prebuilt* `tollgate-wrt` as an OpenWrt `.apk`

These tools turn an already-verified cross-compiled binary into an installable
OpenWrt package for a concrete SDK target, and prove afterwards that the
artifact really contains those bytes. They exist because upstream's own
`scripts/build-sdk-package.sh` **rebuilds** the Go binaries inside the run
(pinned Go toolchain + its own ldflags), which is wrong when the binary you must
ship is the one that was already built and verified from a pinned commit.

The staging contract is still upstream's: `packaging/Makefile` expects the two
prebuilt binaries next to it (`PREBUILT_BIN` / `PREBUILT_CLI`) — "The Go binaries
are built natively by CI and staged into `$(PKG_MAKEFILE_DIR)`; the SDK only
packages them."

| file | purpose |
|---|---|
| `package-prebuilt-apk.sh` | stage `packaging/` + verified binaries as a `src-link` feed, run the SDK, copy the `.apk` out |
| `verify-apk.sh` | metadata + payload + arch + provenance verification of a produced `.apk` |
| `test-verify-apk.sh` | regression test for `verify-apk.sh` (accepts a good artifact, rejects a truncated one, never passes CLI provenance silently) |
| `test-package-prebuilt-apk.sh` | regression test for `package-prebuilt-apk.sh` — runs with a stub `docker`, so no SDK: guards (missing version, sha mismatch, wrong REPO_DIR) plus the staged feed must carry the verified bytes byte-for-byte and the artifact must come out under `<name>_<version>_<arch>.apk` |
| `lib-sdk-container.sh` | the docker lifecycle every SDK run must use: `--rm` + a `trap` that reaps the container **with volumes**, the label-scoped reaper for SIGKILLed runs, and the post-run "did this run leak a volume?" assertion |
| `check-dangling-sdk-volumes.sh` | generic post-build guard: exit 1 (or `--warn-only`) if any dangling docker volume exists; `--reap` also clears stale labelled build containers |
| `test-sdk-volume-leak-guard.sh` | regression test for the VOLUME leak (stub `docker`, no SDK): `--rm` present, `rm -f -v` everywhere, pre-run reaper, SIGTERM mid-build cleans up immediately, and a leaked volume makes the run **fail loudly** |
| `test-sdk-volume-lifecycle-docker.sh` | opt-in (`FD3_DOCKER_IT=1`) real-docker lifecycle test on the actual `openwrt/sdk` image: reproduces the old `docker rm -f` leak, proves `--rm` reclaims it, proves the reaper closes the SIGKILL hole |
| `evidence/fd3-aarch64-apk-verification.txt` | verbatim transcript of the verification for the artifact below |

## The artifact (FD3, 2026-09-20)

```
path:    ~/worktrees/fd3-upstream-build/dist/tollgate-wrt_main.98.040dd7fa_aarch64_cortex-a53.apk
size:    7611771 bytes
sha256:  fb893695e80371b6b4b981b6da6cc8665b2dac0149e6bc1500f02951e2fcd899
name:    tollgate-wrt
version: 0.0.0_git98-r0     (normalize-apk-version.sh of PACKAGE_VERSION=main.98.040dd7fa)
arch:    aarch64_cortex-a53 (NOT `all`, not a host arch)
depends: libc
provides:nodogsplash-files=0.0.0_git98-r0, tollgate-wrt-any
payload: 73 files; usr/bin/tollgate-wrt (service) + usr/bin/tollgate (CLI), both ELF ARM aarch64
```

Pinned source: `OpenTollGate/tollgate-module-basic-go` `upstream/main`
`040dd7facae56ebc5689437a1b7039e0b45d2da0` ("fix(merchant): explain and
pre-check the mint swap fee (#409)"), `VERSION` = `v0.6.0-alpha2`.

Verified inputs (sha256 checked before staging):

```
build/tollgate-wrt-linux-arm64  bb213a75dec470c46a38b448fc49fcb16b5585538b6e3ea39bfc1b35c5d5c029
bin/arm64/tollgate              09fc29d3b5e61a22e4dfe8db22ea5c3a8a5a6b78f4db5bbe1a504507067d4dd0
```

## Exact commands

Package (this is what produced the artifact above; `PACKAGE_VERSION` is the value
CI passes down, derived from the pinned commit through the APK version
normaliser):

```sh
cd ~/repos/feed
SDK_IMAGE=openwrt/sdk:mediatek-filogic-v25.12.5 \
REPO_DIR=~/worktrees/fd3-upstream-build/repo \
BIN_DIR=~/worktrees/fd3-upstream-build/build \
BIN_SERVICE=tollgate-wrt-linux-arm64 \
BIN_CLI=../bin/arm64/tollgate \
BIN_SHA256=bb213a75dec470c46a38b448fc49fcb16b5585538b6e3ea39bfc1b35c5d5c029 \
PACKAGE_VERSION=main.98.040dd7fa \
OUT_DIR=~/worktrees/fd3-upstream-build/dist \
bash tools/fd3-apk/package-prebuilt-apk.sh
```

Verify + test:

```sh
bash tools/fd3-apk/verify-apk.sh <artifact.apk>        # metadata/payload/arch/provenance
bash tools/fd3-apk/test-verify-apk.sh                  # 6 assertions
bash tools/fd3-apk/test-package-prebuilt-apk.sh        # 18 assertions, stub docker (no SDK)
bash tools/fd3-apk/test-sdk-volume-leak-guard.sh       # 22 assertions, stub docker (no SDK)
FD3_DOCKER_IT=1 bash tools/fd3-apk/test-sdk-volume-lifecycle-docker.sh   # real docker + real SDK image
bash tools/fd3-apk/check-dangling-sdk-volumes.sh       # post-build guard: no orphaned volumes
```

`BIN_CLI` may carry path components (`../bin/arm64/tollgate`) — it is staged under
its **basename**, which is what `packaging/Makefile` reads.

Inside the SDK container the packaging step is exactly:

```sh
cd /builder
cp feeds.conf.default feeds.conf
echo "src-link tollgate /workspace" >> feeds.conf
./scripts/feeds update packages luci tollgate
./scripts/feeds install -a -p tollgate
make defconfig && echo -e "CONFIG_PACKAGE_tollgate-wrt=y\nCONFIG_USE_APK=y" >> .config && make defconfig
env USE_UPX=0 make -j"$(nproc)" package/feeds/tollgate/tollgate-wrt/compile V=s
# -> bin/packages/aarch64_cortex-a53/tollgate/tollgate-wrt-0.0.0_git98-r0.apk
```

Install on the router (untrusted local file):

```sh
apk add --allow-untrusted ./tollgate-wrt_main.98.040dd7fa_aarch64_cortex-a53.apk
# or, signature-free local feed: apk --allow-untrusted add --repository <dir> tollgate-wrt
```

## The `openwrt/sdk` anonymous-VOLUME trap (fixed here 2026-09-20)

`openwrt/sdk:<target>-<release>` declares `/builder` as a docker **VOLUME**. Every
`docker run` of that image therefore allocates a fresh anonymous volume (~1.5 GB
once populated), and `docker rm -f <container>` does **not** reclaim it — only
`--rm` at run time, or `docker rm -v`, does.

This helper originally did `docker run -d --name "$CONTAINER" … sleep infinity` and
`docker rm -f "$CONTAINER"`. The run that produced the artifact above used that
version, was killed at the harness timeout, and every retry repeated it: **six
anonymous volumes = 8.895 GB**, found three hours later by the disk pass of
2026-09-20 (it was 60 % of that box's +14.7 GB regrowth). It is invisible to the
usual triage — `docker ps -a` is clean and the volumes are young, so no age sweep
flags them. Check with `docker volume ls -f dangling=true -q` and
`docker system df -v` (`LINKS=0`).

What the helper does now:

1. `docker run -d --rm --name "$CONTAINER" --label hermes.sdk-build=1 …` — `--rm`
   is what reclaims the volume when the container exits.
2. the long build step runs as a background job that the script `wait`s on, under
   `trap … EXIT INT TERM HUP`, so a SIGTERM/SIGINT/SIGHUP is handled *immediately*
   instead of after the build step finishes (that deferral is exactly how the
   8.895 GB happened) and the container is removed with `docker rm -f -v`.
3. a pre-run reaper removes a same-named container left by a SIGKILLed run.
4. after the run the helper asserts it added **no** new dangling volume and exits
   non-zero (naming the volume, the size, and the `docker volume rm` fix) if it
   did — a leak can no longer be reported as a success.
5. `check-dangling-sdk-volumes.sh` is the generic, repo-independent guard: run it
   after any SDK build, and `--reap` to clear stale labelled build containers.

Evidence: `evidence/` (stub-docker RED before the fix / GREEN after, the
real-docker lifecycle transcript, and the post-fix re-run of this very build).

## Known gaps (recorded, not hidden)

1. **CLI carries no version string.** `bin/arm64/tollgate` was cross-compiled
   with a plain `go build` — the repo's `cli_ldflags` helper
   (`-X 'main.version=$PACKAGE_VERSION'`) was not applied — so `go version -m`
   shows no `-ldflags` and `tollgate version` prints empty. `verify-apk.sh`
   therefore attests provenance from the **service** binary (which does carry
   `main.98.040dd7fa`) and emits an explicit `WARN` for the CLI. Fix belongs in
   the cross-compile step, not here.
2. **SDK image.** The artifact was built with `openwrt/sdk:mediatek-filogic-v25.12.5`,
   matching this repo's CI pin (`ci(feed): pin release SDK images to v25.12.5`,
   ebbb18836). Upstream `packaging/build-inputs.json` pins `openwrt_sdk.release
   = 25.12.0` by digest for `mediatek-filogic`; the arch string and ABI are the
   same, but a build from that exact digest has not been run here.
3. **Toolchain drift.** The prebuilt binaries report `go1.26.0`, while
   `packaging/build-inputs.json` pins Go `1.25.8`. The artifact is therefore not
   byte-reproducible against upstream's declared input tuple. Only the verified
   prebuilt bytes were packaged — that was the point of the task — so the drift
   is recorded rather than papered over.
4. `sstrip`/`rstrip.sh` rewrites the packaged binaries, so their sha256 differs
   from the inputs by design (`11796642 → 11763707` service,
   `6684834 → 6640609` CLI bytes). Provenance is asserted via the embedded
   version string, not byte equality.

## Notes on the feed

This directory is packaging *tooling*; `net/tollgate-wrt/` remains the
source-built feed (`golang-package.mk` from the upstream release tarball) and is
untouched by these scripts.
