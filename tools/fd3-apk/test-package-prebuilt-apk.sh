#!/usr/bin/env bash
# Regression test for package-prebuilt-apk.sh — runs WITHOUT Docker.
#
#   bash tools/fd3-apk/test-package-prebuilt-apk.sh
#
#   A1 bash -n syntax of all three tools
#   A2 shellcheck (skipped when not installed)
#   A3 verify-apk.sh regression test (test-verify-apk.sh)
#   A4 refuses to run without PACKAGE_VERSION
#   A5 refuses to package when the input sha256 does not match BIN_SHA256
#   A6 refuses a REPO_DIR that is not the upstream checkout
#   A7 end-to-end with a STUB docker: the staged feed must carry the verified
#      bytes byte-for-byte plus upstream's packaging/ files, and the artifact
#      must be copied out under <name>_<version>_<arch>.apk with unchanged sha256
#
# Env overrides: FD3_W (worktree), FD3_APK, FD3_BIN_SHA256, FD3_VERSION
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

printf '# test: package-prebuilt-apk.sh (stub docker, no SDK)\n'

for s in package-prebuilt-apk.sh verify-apk.sh test-verify-apk.sh; do
    if bash -n "$TOOLS/$s"; then ok "A1 bash -n $s"; else bad "A1 bash -n $s"; fi
done

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S warning "$TOOLS"/*.sh; then ok "A2 shellcheck -S warning clean"; else bad "A2 shellcheck findings"; fi
else
    printf 'skip - A2 shellcheck not installed\n'
fi

out="$(bash "$TOOLS/test-verify-apk.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "0 failed"; then
    ok "A3 verify-apk.sh regression test green"
else
    bad "A3 verify-apk.sh regression test rc=$rc"
fi

o="$(REPO_DIR="$REPO" BIN_DIR="$BIN" BIN_SHA256="$SHA" bash "$TOOLS/package-prebuilt-apk.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$o" | grep -q "PACKAGE_VERSION is required"; then
    ok "A4 refuses to run without PACKAGE_VERSION"
else
    bad "A4 missing-version guard (rc=$rc)"
fi

o="$(REPO_DIR="$REPO" BIN_DIR="$BIN" BIN_SHA256="0000000000000000000000000000000000000000000000000000000000000000" \
     PACKAGE_VERSION="$VER" OUT_DIR="$T/out" bash "$TOOLS/package-prebuilt-apk.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$o" | grep -q "Refusing to package unverified bytes"; then
    ok "A5 refuses to package on sha256 mismatch"
else
    bad "A5 sha256 guard (rc=$rc)"
fi

mkdir -p "$T/notrepo"
o="$(REPO_DIR="$T/notrepo" BIN_DIR="$BIN" BIN_SHA256="$SHA" PACKAGE_VERSION="$VER" \
     bash "$TOOLS/package-prebuilt-apk.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$o" | grep -q "packaging/Makefile missing"; then
    ok "A6 refuses a REPO_DIR without packaging/Makefile"
else
    bad "A6 repo guard (rc=$rc)"
fi

[ -f "$APK" ] || { bad "A7 artifact under test missing: $APK"; printf '\n%d passed, %d failed\n' "$p" "$f"; exit 1; }
mkdir -p "$T/bin" "$T/stub" "$T/out"
cp "$BIN/tollgate-wrt-linux-arm64" "$T/bin/" 2>/dev/null || true
cp "$W/bin/arm64/tollgate" "$T/bin/" 2>/dev/null || true
: > "$T/rec"

cat > "$T/stub/docker" <<'STUBEOF'
#!/usr/bin/env bash
case "$1" in
  rm) exit 0 ;;
  run)
    for a in "$@"; do case "$a" in */workspace:ro) SRC="${a%:/workspace:ro}" ;; esac; done
    echo "run feed_src=${SRC:-none}" >> "$STUB_REC"
    [ -n "${SRC:-}" ] && printf 'feed_src_perm %s\n' "$(stat -c '%a' "$SRC")" >> "$STUB_REC"
    [ -n "${SRC:-}" ] && (cd "$SRC" && find . -type f | sort | while read -r r; do
        printf 'staged %s %s\n' "${r#./}" "$(sha256sum "$r" | awk '{print $1}')"; done) >> "$STUB_REC"
    echo stub-container; exit 0 ;;
  exec)
    case "$*" in *"find /builder/bin/packages"*) echo "/builder/bin/packages/aarch64_cortex-a53/tollgate/tollgate-wrt-0.0.0_git98-r0.apk" ;; esac
    exit 0 ;;
  cp)
    src="${@: -2:1}"; dst="${@: -1}"
    echo "cp $src -> $dst" >> "$STUB_REC"
    cp "$STUB_APK" "$dst"; exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$T/stub/docker"

o="$(PATH="$T/stub:$PATH" STUB_REC="$T/rec" STUB_APK="$APK" \
     SDK_IMAGE=openwrt/sdk:mediatek-filogic-v25.12.5 REPO_DIR="$REPO" BIN_DIR="$T/bin" \
     BIN_SERVICE=tollgate-wrt-linux-arm64 BIN_CLI=tollgate \
     BIN_SHA256="$SHA" PACKAGE_VERSION="$VER" OUT_DIR="$T/out" \
     CONTAINER=stub bash "$TOOLS/package-prebuilt-apk.sh" 2>&1)"; rc=$?

if [ "$rc" -eq 0 ]; then ok "A7 stub run exit 0"; else bad "A7 stub run rc=$rc"; printf '%s\n' "$o" | sed 's/^/       | /'; fi
if printf '%s' "$o" | grep -q "service binary sha256=$SHA"; then ok "A7 verified input echoed"; else bad "A7 input verification line missing"; fi
if grep -q "staged net/tollgate-wrt/tollgate-wrt $SHA" "$T/rec"; then
    ok "A7 staged service binary is byte-identical to the verified input"
else
    bad "A7 staged service binary sha mismatch"
fi
for want in net/tollgate-wrt/Makefile net/tollgate-wrt/tollgate net/tollgate-wrt/LICENSE \
            net/tollgate-wrt/normalize-apk-version.sh net/tollgate-wrt/preinst; do
    if grep -q "^staged ${want} " "$T/rec"; then ok "A7 staged $want"; else bad "A7 staged $want missing"; fi
done
if grep -q "^staged net/tollgate-wrt/files/" "$T/rec"; then
    ok "A7 staged the runtime files/ tree ($(grep -c '^staged net/tollgate-wrt/files/' "$T/rec") files)"
else
    bad "A7 staged net/tollgate-wrt/files/ tree missing"
fi
ART="$T/out/tollgate-wrt_${VER}_aarch64_cortex-a53.apk"
if [ -f "$ART" ] && [ "$(sha256sum "$ART" | awk '{print $1}')" = "$(sha256sum "$APK" | awk '{print $1}')" ]; then
    ok "A7 artifact copied out as $(basename "$ART") with matching sha256"
else
    bad "A7 artifact copy/name/sha256"
fi

# A8: the SDK container runs as buildbot(1000); `mktemp -d` is 0700 owned by the
# invoking uid, so the :ro feed is unreadable whenever the two differ and the build
# dies far away with "No rule to make target 'package/feeds/tollgate/...'".
FSPERM="$(awk '$1=="feed_src_perm"{m=$2} END{print m}' "$T/rec")"
if [ -n "$FSPERM" ] && [ "$(( FSPERM % 10 ))" -ge 5 ]; then
    ok "A8 :ro feed source traversable by the container's buildbot uid (mode $FSPERM)"
else
    bad "A8 :ro feed source not readable by the container user (mode ${FSPERM:-none})"
fi

printf '\n%d passed, %d failed\n' "$p" "$f"
[ "$f" -eq 0 ]
