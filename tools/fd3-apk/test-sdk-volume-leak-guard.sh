#!/usr/bin/env bash
# Regression test for the openwrt/sdk docker anonymous-VOLUME leak — runs WITHOUT a
# real SDK container (stub `docker` on PATH).
#
#   bash tools/fd3-apk/test-sdk-volume-leak-guard.sh
#
# Background: `openwrt/sdk:*` declares /builder as a docker VOLUME, so every
# `docker run` allocates a fresh ~1.5 GB anonymous volume; `docker rm -f` (no -v)
# never reclaims it. On 2026-09-20 a six-retry packaging run leaked 8.895 GB.
#
#   B1 docker run of the SDK uses --rm (so the volume dies with the container)
#   B2 docker run carries the hermes.sdk-build=1 label (scopes the stale-run reaper)
#   B3 a same-named container left by a killed previous run is reaped BEFORE the run
#   B4 the container is removed with `docker rm -f -v` on the happy path
#   B5 SIGTERM mid-build is handled immediately (not deferred to the end of the
#      build step) and the container + its volumes are removed
#   B6 the happy path fails LOUDLY (exit non-zero, names the volume) if the run
#      added a dangling volume
#   B7 a pre-existing dangling volume is only warned about, it does not fail a run
#      that leaked nothing
#   C1-C3 check-dangling-sdk-volumes.sh: clean -> 0, dangling -> 1, --warn-only -> 0
set -uo pipefail

TOOLS="$(cd "$(dirname "$0")" && pwd)"
W="${FD3_W:-/home/c03rad0r/worktrees/fd3-upstream-build}"
APK="${FD3_APK:-$W/dist/tollgate-wrt_main.98.040dd7fa_aarch64_cortex-a53.apk}"
SHA="${FD3_BIN_SHA256:-bb213a75dec470c46a38b448fc49fcb16b5585538b6e3ea39bfc1b35c5d5c029}"
VER="${FD3_VERSION:-main.98.040dd7fa}"
REPO="$W/repo"
BIN="$W/build"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

p=0; f=0
ok()  { p=$((p + 1)); printf 'ok   - %s\n' "$1"; }
bad() { f=$((f + 1)); printf 'FAIL - %s\n' "$1"; }

printf '# test: openwrt/sdk anonymous-volume leak guard (stub docker)\n'

for s in lib-sdk-container.sh package-prebuilt-apk.sh check-dangling-sdk-volumes.sh; do
    if bash -n "$TOOLS/$s"; then ok "bash -n $s"; else bad "bash -n $s"; fi
done

# --- stub docker -------------------------------------------------------------
# Records every invocation to $STUB_REC. `volume ls` output is phase-driven:
# vol_1, vol_2, ... emit in order (STUB_VOL_FIXED overrides with one fixed state).
mkdir -p "$T/stub" "$T/vol" "$T/out" "$T/bin"
cp "$BIN/tollgate-wrt-linux-arm64" "$T/bin/" 2>/dev/null || true
cp "$W/bin/arm64/tollgate" "$T/bin/" 2>/dev/null || true

cat > "$T/stub/docker" <<'STUBEOF'
#!/usr/bin/env bash
rec() { printf '%s\n' "$*" >> "$STUB_REC"; }
case "$1" in
  volume)
    case "$2" in
      ls)
        n="$(cat "$STUB_VOLN" 2>/dev/null || echo 0)"; n=$((n + 1)); printf '%s' "$n" > "$STUB_VOLN"
        rec "volume ls #$n"
        if [ -n "${STUB_VOL_FIXED:-}" ]; then cat "$STUB_VOL_FIXED"
        elif [ -f "$STUB_VOL_DIR/vol_$n" ]; then cat "$STUB_VOL_DIR/vol_$n"
        fi
        exit 0 ;;
      inspect)
        for a in "$@"; do case "$a" in *'{{.Labels}}'*) echo 'map[com.docker.volume.anonymous:]'; exit 0 ;; esac; done
        echo '{}'; exit 0 ;;
    esac
    exit 0 ;;
  system)
    rec "system $*"
    echo 'Images'
    echo "VOLUME NAME  LINKS  SIZE"
    [ -n "${STUB_VOL_FIXED:-}" ] && awk '{print $1"  0  1.5GB"}' "$STUB_VOL_FIXED"
    exit 0 ;;
  rm)
    rec "rm $*"
    exit 0 ;;
  run)
    rec "run $*"
    echo stub-container-id; exit 0 ;;
  exec)
    rec "exec $*"
    case "$*" in
      *"find /builder/bin/packages"*) echo "/builder/bin/packages/aarch64_cortex-a53/tollgate/tollgate-wrt-0.0.0_git98-r0.apk"; exit 0 ;;
    esac
    sleep "${STUB_EXEC_SLEEP:-0}"; exit "${STUB_EXEC_RC:-0}" ;;
  cp)
    rec "cp $*"
    dst="${@: -1}"; cp "$STUB_APK" "$dst"; exit 0 ;;
  ps)
    exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$T/stub/docker"

run_helper() { # $1 = rec file, rest = env assignments
    local rec="$1"; shift
    : > "$rec"
    rm -f "$T/voln"; printf '0' > "$T/voln"
    env PATH="$T/stub:$PATH" STUB_REC="$rec" STUB_VOL_DIR="$T/vol" STUB_VOLN="$T/voln" \
        STUB_APK="$APK" STUB_EXEC_SLEEP="${STUB_EXEC_SLEEP:-0}" ${STUB_VOL_FIXED:+STUB_VOL_FIXED="$STUB_VOL_FIXED"} \
        SDK_IMAGE=openwrt/sdk:mediatek-filogic-v25.12.5 REPO_DIR="$REPO" BIN_DIR="$T/bin" \
        BIN_SERVICE=tollgate-wrt-linux-arm64 BIN_CLI=tollgate BIN_SHA256="$SHA" \
        PACKAGE_VERSION="$VER" OUT_DIR="$T/out" CONTAINER=stub-ct "$@" \
        timeout 60 bash "$TOOLS/package-prebuilt-apk.sh" 2>&1
}

[ -f "$APK" ] || { bad "artifact under test missing: $APK"; printf '\n%d passed, %d failed\n' "$p" "$f"; exit 1; }
rm -f "$T/vol/vol_"* 2>/dev/null || true

# --- B1/B2/B3: run shape + pre-run reaper ------------------------------------
rec="$T/rec1"
o="$(run_helper "$rec")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "B0 stub run exit 0"; else bad "B0 stub run rc=$rc"; printf '%s\n' "$o" | sed 's/^/       | /'; fi

runline="$(grep -m1 '^run ' "$rec" || true)"
case "$runline" in
  *" --rm "*) ok "B1 docker run uses --rm" ;;
  *) bad "B1 docker run missing --rm: $runline" ;;
esac
case "$runline" in
  *"hermes.sdk-build=1"*) ok "B2 docker run carries the SDK build label" ;;
  *) bad "B2 docker run label missing: $runline" ;;
esac
order="$(grep -nE '^(rm|run) ' "$rec" | head -2 | tr '\n' '|')"
case "$order" in
  *"rm "*"run "*) ok "B3 stale same-named container is reaped before the run" ;;
  *) bad "B3 no pre-run reaper (got: $order)" ;;
esac
if [ "$(grep -c '^rm ' "$rec")" -ge 1 ] && ! grep '^rm ' "$rec" | grep -qv ' -v '; then
    ok "B4 container removed with -v on the happy path ($(grep -c '^rm ' "$rec") rm call(s), all -v)"
else
    bad "B4 rm without -v: $(grep '^rm ' "$rec" | tr '\n' '|')"
fi
if grep -qE '^rm rm -f -v stub-ct' "$rec"; then ok "B4 rm targets the SDK container by name"; else bad "B4 rm did not target stub-ct ($(grep '^rm ' "$rec" | tr '\n' '|'))"; fi

# --- B7: pre-existing orphan does not fail an otherwise clean run -------------
printf 'preexisting-orphan' > "$T/vol/vol_1"
printf 'preexisting-orphan' > "$T/vol/vol_2"
o="$(run_helper "$T/rec2")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "B7 pre-existing dangling volume does not fail a clean run"; else bad "B7 clean run failed rc=$rc"; printf '%s\n' "$o" | sed 's/^/       | /'; fi
if printf '%s' "$o" | grep -q 'WARN: 1 dangling docker volume(s) predate this run'; then
    ok "B7 pre-existing orphan is warned about explicitly"
else
    bad "B7 pre-existing orphan warning missing"
fi

# --- B6: a NEW dangling volume after the run must fail loudly ----------------
rm -f "$T/vol/vol_"*; : > "$T/vol/vol_1"; printf 'leakedvol123' > "$T/vol/vol_2"
o="$(run_helper "$T/rec3")"; rc=$?
if [ "$rc" -ne 0 ]; then ok "B6 leaked volume -> non-zero exit (rc=$rc)"; else bad "B6 leaked volume still exited 0"; fi
if printf '%s' "$o" | grep -q 'leakedvol123'; then ok "B6 failure names the leaked volume id"; else bad "B6 leaked volume id not reported"; fi
if printf '%s' "$o" | grep -q 'leaked 1 anonymous docker volume'; then ok "B6 failure states the leak count"; else bad "B6 leak count missing"; fi
if printf '%s' "$o" | grep -q 'docker volume rm'; then ok "B6 failure prints the remediation command"; else bad "B6 remediation hint missing"; fi

# --- B5: SIGTERM mid-build cleans up immediately ------------------------------
rm -f "$T/vol/vol_"*; : > "$T/vol/vol_1"; : > "$T/vol/vol_2"
rec="$T/rec4"; : > "$rec"; rm -f "$T/voln"; printf '0' > "$T/voln"
STUB_EXEC_SLEEP=30 env PATH="$T/stub:$PATH" STUB_REC="$rec" STUB_VOL_DIR="$T/vol" STUB_VOLN="$T/voln" \
    STUB_APK="$APK" SDK_IMAGE=openwrt/sdk:mediatek-filogic-v25.12.5 REPO_DIR="$REPO" BIN_DIR="$T/bin" \
    BIN_SERVICE=tollgate-wrt-linux-arm64 BIN_CLI=tollgate BIN_SHA256="$SHA" \
    PACKAGE_VERSION="$VER" OUT_DIR="$T/out" CONTAINER=stub-ct \
    bash "$TOOLS/package-prebuilt-apk.sh" > "$T/out4" 2>&1 &
spid=$!
sleep 3
t0="$(date +%s)"
kill -TERM "$spid" 2>/dev/null || true
wait "$spid"; rc=$?
t1="$(date +%s)"
elapsed=$((t1 - t0))
if [ "$rc" -ne 0 ]; then ok "B5 interrupted run exits non-zero (rc=$rc)"; else bad "B5 interrupted run exited 0"; fi
if [ "$elapsed" -lt 10 ]; then ok "B5 SIGTERM handled immediately (${elapsed}s, build step sleeps 30s)"; else bad "B5 SIGTERM deferred ${elapsed}s"; fi
if grep -qE '^rm rm -f -v stub-ct' "$rec"; then ok "B5 SIGTERM path removes the container WITH volumes"; else bad "B5 no rm -f -v on the SIGTERM path ($(grep '^rm ' "$rec" | tr '\n' '|'))"; fi
if grep -q 'interrupted by signal' "$T/out4"; then ok "B5 interruption is reported on stderr"; else bad "B5 no interruption message"; fi

# --- C1-C3: generic guard ----------------------------------------------------
: > "$T/vol_fixed"
o="$(PATH="$T/stub:$PATH" STUB_REC="$T/recc" STUB_VOL_FIXED="$T/vol_fixed" bash "$TOOLS/check-dangling-sdk-volumes.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$o" | grep -q 'ok: no dangling docker volumes'; then ok "C1 guard passes on a clean host"; else bad "C1 guard clean host rc=$rc"; fi

printf 'leakedvol123\n' > "$T/vol_fixed"
o="$(PATH="$T/stub:$PATH" STUB_REC="$T/recc" STUB_VOL_FIXED="$T/vol_fixed" bash "$TOOLS/check-dangling-sdk-volumes.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$o" | grep -q 'leakedvol123'; then ok "C2 guard fails loudly on a dangling volume"; else bad "C2 guard rc=$rc"; fi

o="$(PATH="$T/stub:$PATH" STUB_REC="$T/recc" STUB_VOL_FIXED="$T/vol_fixed" bash "$TOOLS/check-dangling-sdk-volumes.sh" --warn-only 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "C3 --warn-only downgrades to exit 0"; else bad "C3 --warn-only rc=$rc"; fi

printf '\n%d passed, %d failed\n' "$p" "$f"
[ "$f" -eq 0 ]
