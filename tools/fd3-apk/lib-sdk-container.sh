#!/usr/bin/env bash
# lib-sdk-container.sh — docker-lifecycle helpers for helpers that run
# `openwrt/sdk:*` images (source me; do not execute).
#
# WHY THIS EXISTS
#   `openwrt/sdk:<target>-<release>` declares `/builder` as a docker VOLUME. Every
#   `docker run` of that image therefore allocates a FRESH anonymous volume
#   (~1.5 GB once populated with staging_dir/build_dir/feeds). `docker rm -f <ct>`
#   does NOT reclaim it — only `--rm` at run time or `docker rm -v` does.
#
#   Measured on CobradorWave 2026-09-20: one net4sats packaging card that timed out
#   and retried six times leaked six anonymous volumes = 8.895 GB, silently. It
#   hides well: `docker ps -a` is empty and the volumes are young, so no
#   age-based sweep flags them.
#
#   So: (1) always `docker run --rm`, (2) always `docker rm -f -v`, (3) run the
#   container under `trap ... INT TERM HUP EXIT` so the timeout/kill path cleans
#   up too, and (4) assert afterwards that the run added no dangling volume, and
#   fail loudly if it did.
set -uo pipefail

# Snapshot of dangling (anonymous/orphaned) volume ids, sorted. Compare two
# snapshots with sdk_assert_no_new_dangling_volumes to attribute leaks to one run
# without tripping over volumes that were already dangling before it started.
sdk_volume_snapshot() {
    docker volume ls -f dangling=true -q 2>/dev/null | grep -v '^$' | sort || true
}

# Remove container `$1` AND its anonymous volumes. Idempotent: a missing
# container is not an error (with --rm it is usually already gone).
sdk_cleanup_container() {
    local name="${1:-}"
    [ -n "$name" ] || return 0
    docker rm -f -v "$name" >/dev/null 2>&1 || true
}

# Human-readable details for leaked volume ids (stdin), for the failure message.
sdk_describe_volumes() {
    local v labels size
    while read -r v; do
        [ -n "$v" ] || continue
        labels="$(docker volume inspect --format '{{.Labels}}' "$v" 2>/dev/null || echo '?')"
        size="$(docker system df -v 2>/dev/null | awk -v id="$v" '$1 == id { print $3 }' || true)"
        printf '  - %s size=%s labels=%s\n' "$v" "${size:-?}" "${labels:-?}"
    done
    printf '%s\n' '  fix: docker volume rm <id>   (or remove the container that created it: docker rm -f -v <ct>)'
    printf '%s\n' '  lint: bash tools/fd3-apk/check-dangling-sdk-volumes.sh'
}

# Fail loudly when the run added dangling volumes. $1 = snapshot taken before the
# run. Returns 1 (with a full report on stderr) when a NEW dangling volume exists.
# Pre-existing dangling volumes are reported as a warning, not a failure, so an
# unrelated stale orphan cannot block this build.
sdk_assert_no_new_dangling_volumes() {
    local before="${1:-}" after leaked preexisting
    after="$(sdk_volume_snapshot)"
    leaked="$(comm -13 <(printf '%s\n' "$before" | grep -v '^$' | sort) \
                       <(printf '%s\n' "$after"  | grep -v '^$' | sort) || true)"
    preexisting="$(comm -12 <(printf '%s\n' "$before" | grep -v '^$' | sort) \
                            <(printf '%s\n' "$after"  | grep -v '^$' | sort) || true)"
    if [ -n "$preexisting" ]; then
        printf 'WARN: %s dangling docker volume(s) predate this run (not caused by it):\n' \
            "$(printf '%s\n' "$preexisting" | grep -c .)" >&2
        printf '%s\n' "$preexisting" | sed 's/^/  - /' >&2
    fi
    [ -n "$leaked" ] || return 0
    {
        printf 'ERROR: this SDK run leaked %s anonymous docker volume(s) — the container was removed without -v (or the run was killed before --rm could fire):\n' \
            "$(printf '%s\n' "$leaked" | grep -c .)"
        printf '%s\n' "$leaked" | sdk_describe_volumes
        printf '%s\n' 'ERROR: refusing to report success with an unreclaimed SDK build volume.'
    } >&2
    return 1
}

# Reap containers left behind by a SIGKILLed/crashed run. Label-scoped: only
# containers carrying the opt-in label are touched, so parallel or foreign builds
# are never at risk. $1 = label (default hermes.sdk-build=1), $2 = max age minutes
# (default 120). Prints what it removed.
sdk_reap_stale_build_containers() {
    local label="${1:-hermes.sdk-build=1}" max_age_min="${2:-120}" id
    for id in $(docker ps -a -q -f "label=$label"); do
        local started age_min now
        started="$(docker inspect --format '{{.State.StartedAt}}' "$id" 2>/dev/null || true)"
        now="$(date +%s)"
        if [ -n "$started" ]; then
            age_min="$(( (now - $(date -d "$started" +%s 2>/dev/null || echo "$now")) / 60 ))"
        else
            age_min=0
        fi
        if [ "$age_min" -ge "$max_age_min" ]; then
            printf '[guard] reaping stale SDK build container %s (age %s min)\n' "$id" "$age_min"
            docker rm -f -v "$id" >/dev/null 2>&1 || true
        fi
    done
    return 0
}
