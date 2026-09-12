#!/bin/sh
# test-index-feed.sh — synthetic end-to-end test of the feed index pipeline
#
# Builds synthetic .apk/.ipk fixtures for a MIX of OpenWrt architecture
# TUPLES (aarch64_cortex-a53, mipsel_24kc, x86_64), runs
# scripts/index-feed.sh over them, and asserts the generated feed tree:
#
#   - one directory per arch TUPLE (never a target name like
#     "mediatek-filogic" — consumers key feed URLs on tuples),
#   - APKINDEX.tar.gz for apk arches, Packages.gz for ipk arches,
#   - artifacts sit FLAT next to their index (self-contained feed dir,
#     opkg/apk resolve Filename relative to the index),
#   - index contents carry package/version/arch records.
#
# Also tests scripts/target-to-arch.sh, the target→tuple map the CI bridge
# job uses to name release assets.
#
# Exit 0 = all pass. Any failure prints FAIL and exits 1.
#
# Usage: sh tests/test-index-feed.sh   (from the repo root)

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INDEX_FEED="$ROOT/scripts/index-feed.sh"
TARGET_MAP="$ROOT/scripts/target-to-arch.sh"

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

# make_apk <file> <name> <version> <arch-tuple>
# APKv2: gzip tarball whose first member is .PKGINFO (key = value lines).
make_apk() {
    f=$1; name=$2; ver=$3; arch=$4
    d=$(mktemp -d -p "$TMP")
    {
        printf 'pkgname = %s\n' "$name"
        printf 'pkgver = %s\n' "$ver"
        printf 'arch = %s\n' "$arch"
        printf 'pkgdesc = synthetic test package\n'
        printf 'size = 12345\n'
        printf 'depend = libc fake-dep\n'
    } > "$d/.PKGINFO"
    mkdir -p "$d/data"
    echo "payload for $name" > "$d/data/file.txt"
    ( cd "$d" && tar -czf "$f" .PKGINFO data )
    rm -rf "$d"
}

# make_ipk <file> <name> <version> <arch-tuple>
# .ipk: ar archive with debian-binary, control.tar.gz, data.tar.gz.
make_ipk() {
    f=$1; name=$2; ver=$3; arch=$4
    d=$(mktemp -d -p "$TMP")
    {
        printf 'Package: %s\n' "$name"
        printf 'Version: %s\n' "$ver"
        printf 'Architecture: %s\n' "$arch"
    } > "$d/control"
    ( cd "$d" && tar -czf control.tar.gz ./control )
    ( cd "$d" && tar -czf data.tar.gz ./control )
    echo "2.0" > "$d/debian-binary"
    ( cd "$d" && ar rc "$f" debian-binary control.tar.gz data.tar.gz )
    rm -rf "$d"
}

# ---------------------------------------------------------------------------
# 1. index-feed.sh over a mixed-arch artifact dir
# ---------------------------------------------------------------------------

echo "== 1. index-feed.sh: mixed-arch synthetic artifacts =="
ART="$TMP/artifacts"; FEED="$TMP/feed"
mkdir -p "$ART" "$FEED"

make_apk "$ART/tollgate-wrt-0.5.0-r1.apk"  tollgate-wrt 0.5.0-r1 aarch64_cortex-a53
make_apk "$ART/tollgate-wrt-0.5.0-r1b.apk" tollgate-wrt 0.5.0-r1 mipsel_24kc
make_ipk "$ART/tollgate-wrt-0.5.0-r1.ipk"  tollgate-wrt 0.5.0-r1 x86_64
# stray files that are NOT packages — must be ignored, not fail the run
echo "not a package" > "$ART/README.txt"
echo "junk" > "$ART/tollgate-wrt-0.5.0.tar.gz"

[ -x "$INDEX_FEED" ] || [ -f "$INDEX_FEED" ] \
    || { fail "scripts/index-feed.sh not found"; exit 1; }

sh "$INDEX_FEED" "$ART" "$FEED" > "$TMP/index.log" 2>&1 \
    || { fail "index-feed.sh exited non-zero"; cat "$TMP/index.log"; exit 1; }

# 1a. one dir per arch TUPLE, no target names, no stray dirs
for a in aarch64_cortex-a53 mipsel_24kc x86_64; do
    [ -d "$FEED/$a" ] && pass "arch dir $a" || fail "missing arch dir $a"
done
[ -d "$FEED/mediatek-filogic" ] && fail "target name used as dir (mediatek-filogic)"
[ -d "$FEED/ramips-mt7621" ]    && fail "target name used as dir (ramips-mt7621)"

# 1b. correct index per format
[ -f "$FEED/aarch64_cortex-a53/APKINDEX.tar.gz" ] \
    && pass "aarch64_cortex-a53/APKINDEX.tar.gz" \
    || fail "missing aarch64_cortex-a53/APKINDEX.tar.gz"
[ -f "$FEED/mipsel_24kc/APKINDEX.tar.gz" ] \
    && pass "mipsel_24kc/APKINDEX.tar.gz" \
    || fail "missing mipsel_24kc/APKINDEX.tar.gz"
[ -f "$FEED/x86_64/Packages.gz" ] \
    && pass "x86_64/Packages.gz" \
    || fail "missing x86_64/Packages.gz"
[ ! -f "$FEED/aarch64_cortex-a53/Packages.gz" ] \
    || fail "unexpected Packages.gz for apk-only arch"

# 1c. artifacts sit FLAT next to the index (self-contained feed)
[ -f "$FEED/aarch64_cortex-a53/tollgate-wrt-0.5.0-r1.apk" ] \
    && pass "apk artifact flat in its arch dir" \
    || fail "apk artifact not copied next to index"
[ -f "$FEED/x86_64/tollgate-wrt-0.5.0-r1.ipk" ] \
    && pass "ipk artifact flat in its arch dir" \
    || fail "ipk artifact not copied next to index"

# 1d. APKINDEX contents: name/version/arch records
if [ -f "$FEED/aarch64_cortex-a53/APKINDEX.tar.gz" ]; then
    idx=$(tar -xzOf "$FEED/aarch64_cortex-a53/APKINDEX.tar.gz" APKINDEX 2>/dev/null || true)
    printf '%s\n' "$idx" | grep -q '^P:tollgate-wrt$' \
        && pass "APKINDEX has P:tollgate-wrt" || fail "APKINDEX missing P: record"
    printf '%s\n' "$idx" | grep -q '^A:aarch64_cortex-a53$' \
        && pass "APKINDEX has A:aarch64_cortex-a53 (tuple)" || fail "APKINDEX missing/wrong A: record"
    printf '%s\n' "$idx" | grep -q '^V:0.5.0-r1$' \
        && pass "APKINDEX has V:0.5.0-r1" || fail "APKINDEX missing V: record"
    printf '%s\n' "$idx" | grep -q '^T:libc fake-dep$' \
        && pass "APKINDEX has T: deps" || fail "APKINDEX missing T: deps"
fi

# 1e. Packages.gz contents: Package/Version/Architecture + SHA256sum
if [ -f "$FEED/x86_64/Packages.gz" ]; then
    pkgs=$(gzip -dc "$FEED/x86_64/Packages.gz" 2>/dev/null || true)
    printf '%s\n' "$pkgs" | grep -q '^Package: tollgate-wrt$' \
        && pass "Packages has Package: tollgate-wrt" || fail "Packages missing Package record"
    printf '%s\n' "$pkgs" | grep -q '^Architecture: x86_64$' \
        && pass "Packages has Architecture: x86_64 (tuple)" || fail "Packages missing/wrong Architecture"
    printf '%s\n' "$pkgs" | grep -q '^SHA256sum: ' \
        && pass "Packages has SHA256sum" || fail "Packages missing SHA256sum"
fi

# ---------------------------------------------------------------------------
# 2. empty artifact dir is NOT a failure
# ---------------------------------------------------------------------------

echo "== 2. index-feed.sh: empty artifact dir exits 0 =="
mkdir -p "$TMP/empty" "$TMP/feed-empty"
if sh "$INDEX_FEED" "$TMP/empty" "$TMP/feed-empty" > "$TMP/empty.log" 2>&1; then
    pass "empty dir exits 0"
else
    fail "empty dir exited non-zero"; cat "$TMP/empty.log"
fi

# ---------------------------------------------------------------------------
# 3. target-to-arch.sh: the CI bridge's target→tuple map
# ---------------------------------------------------------------------------

echo "== 3. target-to-arch.sh: target → arch tuple map =="

if [ ! -f "$TARGET_MAP" ]; then
    fail "scripts/target-to-arch.sh not found"
else
    check_map() { # <target> <expected-tuple>
        got=$(sh "$TARGET_MAP" "$1" 2>/dev/null || true)
        if [ "$got" = "$2" ]; then
            pass "map $1 -> $2"
        else
            fail "map $1 -> '$got' (expected $2)"
        fi
    }
    check_map x86-64            x86_64
    check_map mediatek-filogic  aarch64_cortex-a53
    check_map ramips-mt7621     mipsel_24kc
    check_map ath79-generic     mips_24kc
    check_map mvebu-cortexa9    arm_cortex-a9_vfpv3
    if sh "$TARGET_MAP" no-such-target >/dev/null 2>&1; then
        fail "unknown target must exit non-zero"
    else
        pass "unknown target exits non-zero"
    fi
fi

# ---------------------------------------------------------------------------
# 4. artifact-arch.sh: embedded arch probe used by the release bridge
# ---------------------------------------------------------------------------

echo "== 4. artifact-arch.sh: embedded arch probe =="

ART_PROBE="$ROOT/scripts/artifact-arch.sh"
if [ ! -f "$ART_PROBE" ]; then
    fail "scripts/artifact-arch.sh not found"
else
    got=$(sh "$ART_PROBE" "$ART/tollgate-wrt-0.5.0-r1.apk" 2>/dev/null || true)
    [ "$got" = "aarch64_cortex-a53" ] \
        && pass "probe apk -> aarch64_cortex-a53" \
        || fail "probe apk -> '$got' (expected aarch64_cortex-a53)"
    got=$(sh "$ART_PROBE" "$ART/tollgate-wrt-0.5.0-r1.ipk" 2>/dev/null || true)
    [ "$got" = "x86_64" ] \
        && pass "probe ipk -> x86_64" \
        || fail "probe ipk -> '$got' (expected x86_64)"
    if sh "$ART_PROBE" "$ART/README.txt" >/dev/null 2>&1; then
        fail "probe non-package must exit non-zero"
    else
        pass "probe non-package exits non-zero"
    fi
fi

# ---------------------------------------------------------------------------

echo ""
if [ "$fails" -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "$fails test(s) FAILED"
exit 1
