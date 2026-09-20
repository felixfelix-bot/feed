#!/usr/bin/env bash
# package-prebuilt-apk.sh — package PREBUILT tollgate-wrt binaries as an OpenWrt
# .apk for one SDK target, using the upstream repo's own OpenWrt recipe.
#
#   SDK_IMAGE=openwrt/sdk:mediatek-filogic-v25.12.5 \
#   REPO_DIR=~/worktrees/fd3-upstream-build/repo \
#   BIN_DIR=~/worktrees/fd3-upstream-build/build \
#   BIN_SERVICE=tollgate-wrt-linux-arm64 \
#   BIN_CLI=<cli binary> \
#   BIN_SHA256=bb213a75... \
#   PACKAGE_VERSION=main.98.040dd7fa \
#   OUT_DIR=~/worktrees/fd3-upstream-build/dist \
#   bash tools/fd3-apk/package-prebuilt-apk.sh
#
# Why this exists / why not scripts/build-sdk-package.sh:
#   Upstream's scripts/build-sdk-package.sh rebuilds the Go binaries inside the
#   run (pinned Go toolchain) and then packages them. This task packages an
#   ALREADY VERIFIED prebuilt binary, so we stage the verified bytes instead and
#   let the SDK do only the packaging half. The staging contract is upstream's
#   own: packaging/Makefile expects the two binaries next to it
#   (PREBUILT_BIN/PREBUILT_CLI), i.e. "The Go binaries are built natively by CI
#   and staged into $(PKG_MAKEFILE_DIR)" — see packaging/Makefile.
#
#   The recipe also does not accept a floating binary: BIN_SHA256 is verified
#   before anything is staged, and the script refuses to run on a mismatch.
#
# Result: bin/packages/<arch>/<category>/tollgate-wrt-<version>.apk, copied to
#   OUT_DIR/tollgate-wrt_<PACKAGE_VERSION>_<EXPECTED_ARCH>.apk
#
# Docker lifecycle (see tools/fd3-apk/lib-sdk-container.sh for the full why):
#   `openwrt/sdk:*` declares /builder as a VOLUME, so each run allocates a fresh
#   ~1.5 GB anonymous volume that `docker rm -f` does NOT reclaim. This script
#   therefore (1) runs the container with --rm and a hermes.sdk-build=1 label,
#   (2) reaps a same-named container left over from a killed previous run before
#   starting, (3) waits on the long build step from a background job so
#   SIGTERM/SIGINT/SIGHUP are handled IMMEDIATELY (not after the container
#   command finishes) and the trap removes the container WITH its volumes, and
#   (4) asserts after the run that it added no dangling volume, failing loudly
#   (exit 1) if it did.
set -euo pipefail

SDK_IMAGE="${SDK_IMAGE:-openwrt/sdk:mediatek-filogic-v25.12.5}"
EXPECTED_ARCH="${EXPECTED_ARCH:-aarch64_cortex-a53}"
PACKAGE_VERSION="${PACKAGE_VERSION:?PACKAGE_VERSION is required (e.g. main.98.040dd7fa)}"
REPO_DIR="${REPO_DIR:?REPO_DIR is required (upstream checkout to package from)}"
BIN_DIR="${BIN_DIR:?BIN_DIR is required (directory holding the prebuilt binaries)}"
BIN_SERVICE="${BIN_SERVICE:-tollgate-wrt-linux-arm64}"
BIN_CLI="${BIN_CLI:-}"
BIN_SHA256="${BIN_SHA256:?BIN_SHA256 is required (sha256 of the service binary)}"
OUT_DIR="${OUT_DIR:-$PWD/dist}"
CONTAINER="${CONTAINER:-sdk-fd3-prebuilt}"
SDK_BUILD_LABEL="${SDK_BUILD_LABEL:-hermes.sdk-build=1}"

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$TOOLS_DIR/lib-sdk-container.sh"

REPO_DIR="$(readlink -f "$REPO_DIR")"
BIN_DIR="$(readlink -f "$BIN_DIR")"
OUT_DIR="$(readlink -f "$OUT_DIR")"

# --- input verification (refuse to package unverified bytes) -----------------
[ -f "$REPO_DIR/packaging/Makefile" ] || { echo "ERROR: $REPO_DIR is not the upstream repo (packaging/Makefile missing)" >&2; exit 1; }
SRC_BIN="$BIN_DIR/$BIN_SERVICE"
[ -f "$SRC_BIN" ] || { echo "ERROR: service binary not found: $SRC_BIN" >&2; exit 1; }
ACTUAL_SHA="$(sha256sum "$SRC_BIN" | awk '{print $1}')"
if [ "$ACTUAL_SHA" != "$BIN_SHA256" ]; then
    echo "ERROR: $SRC_BIN sha256=$ACTUAL_SHA does not match BIN_SHA256=$BIN_SHA256" >&2
    echo "Refusing to package unverified bytes." >&2
    exit 1
fi
case "$(file -b "$SRC_BIN")" in
    *"ARM aarch64"*) ;;
    *) echo "ERROR: $SRC_BIN is not an ARM aarch64 ELF" >&2; exit 1 ;;
esac
if [ -n "$BIN_CLI" ]; then
    [ -f "$BIN_DIR/$BIN_CLI" ] || { echo "ERROR: CLI binary not found: $BIN_DIR/$BIN_CLI" >&2; exit 1; }
fi

VERSION="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
echo "[in] repo=$REPO_DIR sha=$VERSION"
echo "[in] service binary sha256=$ACTUAL_SHA ($BIN_SERVICE)"
echo "[in] version=$PACKAGE_VERSION arch=$EXPECTED_ARCH sdk=$SDK_IMAGE"

# --- docker lifecycle: tracked state + interruptible waits + loud guard ------
STAGE=""
FEED=""
CHILD_PID=""
SIGNALLED=0
DANGLING_BEFORE="$(sdk_volume_snapshot)"

cleanup() {
    local code=$?
    if [ -n "$CHILD_PID" ]; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
        CHILD_PID=""
    fi
    # -v is the whole point: `docker rm -f` alone leaves the SDK's /builder volume behind.
    sdk_cleanup_container "$CONTAINER"
    [ -n "$STAGE" ] && rm -rf "$STAGE"
    [ -n "$FEED" ] && rm -rf "$FEED"
    if [ "$SIGNALLED" -eq 1 ]; then
        printf 'ERROR: interrupted by signal — container %s and its volumes were removed.\n' "$CONTAINER" >&2
    fi
    sdk_assert_no_new_dangling_volumes "$DANGLING_BEFORE" || code=1
    exit "$code"
}
on_signal() { SIGNALLED=1; exit 130; }
trap cleanup EXIT
trap on_signal INT TERM HUP

# Interruptible `docker exec`: a signal trap only fires at a command boundary, so
# the long build must run as a background job we `wait` on — otherwise a timeout
# kill would be deferred until the build step finished, which is exactly how the
# 2026-09-20 leak (6 volumes / 8.895 GB) happened.
docker_exec_wait() {
    local rc=0
    docker exec "$@" &
    CHILD_PID=$!
    wait "$CHILD_PID" || rc=$?
    CHILD_PID=""
    return "$rc"
}

# --- stage upstream packaging/ + the verified binaries ----------------------
STAGE="$(mktemp -d)"
cp -r "$REPO_DIR/packaging/." "$STAGE/"
cp "$REPO_DIR/LICENSE" "$STAGE/LICENSE"
cp "$SRC_BIN" "$STAGE/$BIN_SERVICE"
[ -n "$BIN_CLI" ] && cp "$BIN_DIR/$BIN_CLI" "$STAGE/$(basename "$BIN_CLI")"
# packaging/Makefile reads PREBUILT_BIN/PREBUILT_CLI from its own directory.
[ "$BIN_SERVICE" = "tollgate-wrt" ] || cp "$SRC_BIN" "$STAGE/tollgate-wrt"
# Staging contract is basename-based (the Makefile reads PREBUILT_CLI from its own
# dir), so a BIN_CLI carrying path components (README example: ../bin/arm64/tollgate)
# must land as its BASENAME — `cp ... "$STAGE/$BIN_CLI"` would resolve through ".."
# and fail outside the staging dir.
BIN_CLI_BASE="$(basename "$BIN_CLI")"
[ -n "$BIN_CLI" ] && { [ "$BIN_CLI_BASE" = "tollgate" ] || cp "$BIN_DIR/$BIN_CLI" "$STAGE/$BIN_CLI_BASE"; }

# --- stage as a local feed (src-link) like upstream CI does -----------------
FEED="$(mktemp -d)"
mkdir -p "$FEED/net"
cp -r "$STAGE" "$FEED/net/tollgate-wrt"

# Pre-run reaper: reclaim a container (and its anonymous volume) left behind if a
# previous run was SIGKILLed and never reached its cleanup trap.
sdk_cleanup_container "$CONTAINER"
docker run -d --rm --name "$CONTAINER" --label "$SDK_BUILD_LABEL" --platform linux/amd64 \
    -v "$FEED":/workspace:ro \
    -v "$HOME/sdk-run/mediatek-filogic/cache/dl:/builder/dl" \
    "$SDK_IMAGE" sleep infinity >/dev/null
docker_exec_wait "$CONTAINER" bash -lc 'cd /builder && [ -d scripts ] || ./setup.sh'

if ! docker_exec_wait -e PACKAGE_VERSION="$PACKAGE_VERSION" "$CONTAINER" bash -lc '
set -euo pipefail
cd /builder
cp feeds.conf.default feeds.conf
grep -q "^src-link tollgate" feeds.conf || echo "src-link tollgate /workspace" >> feeds.conf
./scripts/feeds update packages luci tollgate >/dev/null
./scripts/feeds install -a -p tollgate
./scripts/feeds install jq luci >/dev/null
make defconfig >/dev/null
{
  echo "CONFIG_PACKAGE_tollgate-wrt=y"
  echo "CONFIG_USE_APK=y"
} >> .config
make defconfig >/dev/null
env USE_UPX=0 make -j"$(nproc)" package/feeds/tollgate/tollgate-wrt/compile V=s | tail -5
find bin/packages -type f -name "*.apk"
'; then
    echo "ERROR: SDK build step failed inside container $CONTAINER" >&2
    exit 1
fi

PKG="$(docker exec "$CONTAINER" bash -lc "find /builder/bin/packages -type f -name '*.apk' | head -n1")"
[ -n "$PKG" ] || { echo "ERROR: SDK produced no .apk" >&2; exit 1; }
mkdir -p "$OUT_DIR"
docker cp "$CONTAINER:$PKG" "$OUT_DIR/tollgate-wrt_${PACKAGE_VERSION}_${EXPECTED_ARCH}.apk"
sdk_cleanup_container "$CONTAINER"

ART="$OUT_DIR/tollgate-wrt_${PACKAGE_VERSION}_${EXPECTED_ARCH}.apk"
echo "[out] $ART"
ls -la "$ART"
sha256sum "$ART"
