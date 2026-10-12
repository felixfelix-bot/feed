#!/usr/bin/env bash
# check-dangling-sdk-volumes.sh — generic post-build guard.
#
#   bash tools/fd3-apk/check-dangling-sdk-volumes.sh            # exit 1 on any dangling volume
#   bash tools/fd3-apk/check-dangling-sdk-volumes.sh --warn-only
#   bash tools/fd3-apk/check-dangling-sdk-volumes.sh --reap     # also reap stale labelled build containers
#
# A dangling docker volume is an orphan: nothing references it and nothing will
# ever clean it up. For `openwrt/sdk:*` runs this is the signature of the
# `docker rm -f` (no `-v`) leak — ~1.5 GB per build attempt. Run this after any
# SDK build; it is cheap and needs no SDK.
set -uo pipefail

WARN_ONLY=0
REAP=0
for arg in "$@"; do
    case "$arg" in
        --warn-only) WARN_ONLY=1 ;;
        --reap) REAP=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$here/lib-sdk-container.sh"

if [ "$REAP" -eq 1 ]; then
    sdk_reap_stale_build_containers "hermes.sdk-build=1" "${SDK_REAP_MAX_AGE_MIN:-120}"
fi

dangling="$(sdk_volume_snapshot)"
count="$(printf '%s\n' "$dangling" | grep -c . || true)"

if [ "$count" -eq 0 ]; then
    printf 'ok: no dangling docker volumes\n'
    exit 0
fi

{
    printf '%s dangling docker volume(s) found (orphaned — nothing references them):\n' "$count"
    printf '%s\n' "$dangling" | sdk_describe_volumes
    printf '%s\n' 'A dangling volume is either an openwrt/sdk VOLUME leak (docker rm -f without -v, or a killed run) or other orphaned build scratch.'
} >&2

if [ "$WARN_ONLY" -eq 1 ]; then
    printf 'warn-only: exiting 0\n' >&2
    exit 0
fi
exit 1
