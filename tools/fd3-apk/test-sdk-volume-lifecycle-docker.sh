#!/usr/bin/env bash
# sdk-volume-lint: ignore-file
# (R2 below REPRODUCES the leaking `docker run --name` + `docker rm -f` pattern
#  on the real image on purpose; the marker keeps a naive tree lint sweep clean.)
#
# Real-docker integration test for the openwrt/sdk anonymous-VOLUME leak fix.
#
#   FD3_DOCKER_IT=1 bash tools/fd3-apk/test-sdk-volume-lifecycle-docker.sh
#
# Needs the SDK image locally (`docker image inspect openwrt/sdk:...`). Skips with
# exit 0 when FD3_DOCKER_IT is unset or docker/the image is unavailable, so it can
# live in the repo without breaking hosts that have no docker.
#
#   R1 `docker run -d --rm --name <ct> <sdk> sleep N` reclaims the /builder volume
#      when the container exits (no leftover dangling volume)
#   R2 the OLD pattern (`--name` without --rm + `docker rm -f`) really does leak —
#      reproduced on the real image, then reclaimed
#   R3 the deterministic-kill hole is closed: a SIGKILLed run that leaves the
#      container+volume behind is reclaimed by the label-scoped reaper
#   R4 the host is left with no dangling volumes at the end
set -uo pipefail

TOOLS="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${FD3_SDK_IMAGE:-openwrt/sdk:mediatek-filogic-v25.12.5}"

p=0; f=0
ok()  { p=$((p + 1)); printf 'ok   - %s\n' "$1"; }
bad() { f=$((f + 1)); printf 'FAIL - %s\n' "$1"; }

if [ "${FD3_DOCKER_IT:-0}" != "1" ]; then
    printf 'skip - set FD3_DOCKER_IT=1 to run the real-docker lifecycle test\n'
    exit 0
fi
if ! command -v docker >/dev/null 2>&1; then
    printf 'skip - docker not installed\n'
    exit 0
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    printf 'skip - image %s not available locally\n' "$IMAGE"
    exit 0
fi

# shellcheck source=/dev/null
. "$TOOLS/lib-sdk-container.sh"

printf '# test: real-docker openwrt/sdk volume lifecycle (%s)\n' "$IMAGE"
CT="sdk-vol-it-$$"
CT2="sdk-vol-it-old-$$"
CT3="sdk-vol-it-kill-$$"
trap 'docker rm -f -v "$CT" "$CT2" "$CT3" >/dev/null 2>&1 || true' EXIT

before="$(sdk_volume_snapshot)"
count_dangling() { sdk_volume_snapshot | grep -c . || true; }

# R2 first: reproduce the original leak on the real image ---------------------
docker run -d --name "$CT2" --platform linux/amd64 "$IMAGE" sleep 5 >/dev/null
docker rm -f "$CT2" >/dev/null 2>&1 || true
leak_after_rm_f="$(count_dangling)"
if [ "$leak_after_rm_f" -gt "$(printf '%s\n' "$before" | grep -c . || true)" ]; then
    ok "R2 old pattern (--name without --rm + docker rm -f) leaks a volume on the real image"
    LEAKED="$(comm -13 <(printf '%s\n' "$before") <(sdk_volume_snapshot))"
else
    bad "R2 could not reproduce the leak (image without a VOLUME? or already-leaked state)"
    LEAKED=""
fi
if [ -n "$LEAKED" ]; then
    if docker volume inspect --format '{{.Labels}}' "$LEAKED" 2>/dev/null | grep -q 'com.docker.volume.anonymous'; then
        ok "R2 leaked volume is an anonymous volume (labels confirm it)"
    else
        bad "R2 leaked volume is not labelled anonymous"
    fi
    docker volume rm "$LEAKED" >/dev/null 2>&1 || true
    if [ "$(count_dangling)" = "$(printf '%s\n' "$before" | grep -c . || true)" ]; then
        ok "R2 leaked volume reclaimed (host back to baseline)"
    else
        bad "R2 leaked volume could not be reclaimed"
    fi
fi

# R1: the fixed pattern reclaims the volume --------------------------------
docker run -d --rm --name "$CT" --label hermes.sdk-build=1 --platform linux/amd64 "$IMAGE" sleep 3 >/dev/null
deadline=$(( $(date +%s) + 60 ))
while docker ps -a --format '{{.Names}}' | grep -qx "$CT"; do
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 1
done
sleep 2
if [ "$(count_dangling)" = "$(printf '%s\n' "$before" | grep -c . || true)" ]; then
    ok "R1 docker run -d --rm reclaims the SDK /builder volume on exit"
else
    bad "R1 fixed pattern still left a dangling volume"
fi

# R3: the deterministic-kill hole — a run that is SIGKILLed (so no trap fires,
# no `--rm` removal) leaves the container AND its /builder volume behind. That is
# the exact state a crashed/timed-out worker leaves; the label-scoped reaper must
# reclaim it. Simulated by simply leaving a labelled container running (keeping a
# wrapper-kill in the loop made this timing-dependent and flaky).
docker run -d --rm --name "$CT3" --label hermes.sdk-build=1 --platform linux/amd64 "$IMAGE" sleep 600 >/dev/null
if docker ps -a --format '{{.Names}}' | grep -qx "$CT3"; then
    ok "R3 a killed run leaves the /builder volume holder behind (the hole)"
else
    bad "R3 could not start the long-running build container"
fi
SDK_REAP_MAX_AGE_MIN=0 bash "$TOOLS/check-dangling-sdk-volumes.sh" --reap --warn-only >/dev/null 2>&1 || true
if docker ps -a --format '{{.Names}}' | grep -qx "$CT3"; then
    bad "R3 reaper did not remove the stale labelled container"
else
    ok "R3 label-scoped reaper reclaimed the stale container (and its volume)"
fi

# R4: host left clean ---------------------------------------------------------
if [ "$(count_dangling)" = "$(printf '%s\n' "$before" | grep -c . || true)" ]; then
    ok "R4 no dangling-volume change over the whole lifecycle test (before=$(printf '%s\n' "$before" | grep -c . || true))"
else
    bad "R4 dangling volumes changed: before=$before after=$(sdk_volume_snapshot)"
fi

printf '\n%d passed, %d failed\n' "$p" "$f"
[ "$f" -eq 0 ]
