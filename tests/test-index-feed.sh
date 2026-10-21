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
# 4b. artifact-arch.sh APKv3 path: the adbdump parse must match the REAL
#     apk-tools3 output format (MEASURED 2026-10-21, apk-tools 3.0.8-r0
#     static, against a real 25.12 SDK-built tollgate-wrt APKv3 package):
#
#       #%SCHEMA: 676B6370
#       # ADB block, size: 10272, compat: 0, ver: 0
#       info:
#         name: tollgate-wrt
#         version: 0.6.0_alpha1-r1
#         ...
#         arch: aarch64_cortex-a53
#
#     i.e. UNQUOTED YAML `arch: <tuple>` under `info:`. A parse that only
#     matches quoted values (`arch: "..."`) works against a synthetic JSON
#     stub but fails on every real artifact — exactly what the 2026-10-21
#     consumption run hit. This section pins the real format so the stub
#     cannot drift from reality again.
# ---------------------------------------------------------------------------

echo "== 4b. artifact-arch.sh: real adbdump format (unquoted YAML arch) =="

# A stub apk whose adbdump output is BYTE-FOR-BYTE the real 3.0.8 format
# (unquoted YAML; arch deliberately NOT the first info field).
STUBADB="$TMP/stubadb"; rm -rf "$STUBADB"; mkdir -p "$STUBADB"
cat > "$STUBADB/apk" <<'STUBADB'
#!/bin/sh
case "$1" in
--version) echo "apk-tools 3.0.8-r0 (real-format stub)"; exit 0 ;;
adbdump)
    cat <<'YAML'
#%SCHEMA: 676B6370
# ADB block, size: 10272, compat: 0, ver: 0
info:
  name: tollgate-wrt
  version: 0.6.0_alpha1-r1
  hashes: 46e8ed0c04f953a88f309c86fa4d3d826c7bae25
  description: |
    TollGate turns an OpenWrt router into a Cashu-powered payment gateway.
  arch: aarch64_cortex-a53
  license: GPL-3.0-only
  origin: /workspace/net/tollgate-wrt
  maintainer: Felix <felix@tollgate.me>
  url: https://tollgate.me
  installed-size: 19488818
  depends: # 3 items
    - jq
    - libc
    - nodogsplash
  provides: # 1 items
    - tollgate-wrt-any
paths: # 24 items
  - acl:
      mode: 0755
      user: root
      group: root
YAML
    exit 0 ;;
*) echo "real-format stub apk: unexpected subcommand: $*" >&2; exit 1 ;;
esac
STUBADB
chmod +x "$STUBADB/apk"

V3REAL="$TMP/v3real-format.apk"
printf 'ADBd' > "$V3REAL"
head -c 64 /dev/urandom >> "$V3REAL"

got=$(PATH="$STUBADB:$PATH" sh "$ART_PROBE" "$V3REAL" 2>/dev/null || true)
[ "$got" = "aarch64_cortex-a53" ] \
    && pass "real-format adbdump -> arch parsed (unquoted YAML)" \
    || fail "real-format adbdump parse broken: got '$got' (expected aarch64_cortex-a53)"

# The parse must read `arch:`, not accidentally match `installed-size:` or a
# provides item; and a dump WITHOUT an arch line must hard-fail.
cat > "$STUBADB/apk" <<'STUBADB2'
#!/bin/sh
case "$1" in
--version) echo "apk-tools 3.0.8-r0 (real-format stub)"; exit 0 ;;
adbdump)
    cat <<'YAML'
#%SCHEMA: 676B6370
info:
  name: tollgate-wrt
  version: 0.6.0_alpha1-r1
YAML
    exit 0 ;;
*) echo "real-format stub apk: unexpected subcommand: $*" >&2; exit 1 ;;
esac
STUBADB2
if PATH="$STUBADB:$PATH" sh "$ART_PROBE" "$V3REAL" >/dev/null 2>&1; then
    fail "adbdump without arch must exit non-zero"
else
    pass "adbdump without arch exits non-zero"
fi

# ---------------------------------------------------------------------------
# 5. APKv3 (ADBd, OpenWrt 25.12+): fail loudly without native apk
# ---------------------------------------------------------------------------

echo "== 5. APKv3 handling (hard-fail without apk-tools3) =="

# A minimal v3 stand-in: correct magic, opaque body (the real format is an
# ADB container whose string table is not shell-readable — that's the point).
printf 'ADBd' > "$ART/tollgate-wrt-0.5.0-r1-v3.apk"
head -c 256 /dev/urandom >> "$ART/tollgate-wrt-0.5.0-r1-v3.apk"

if command -v apk >/dev/null 2>&1; then
    echo "  (native apk present — v3 parsing delegated, skipped here)"
    pass "v3 with native apk: delegated"
else
    if sh "$ART_PROBE" "$ART/tollgate-wrt-0.5.0-r1-v3.apk" >/dev/null 2>&1; then
        fail "v3 without apk must exit non-zero"
    else
        msg=$(sh "$ART_PROBE" "$ART/tollgate-wrt-0.5.0-r1-v3.apk" 2>&1 || true)
        case "$msg" in
            *APKv3*|*apk-tools3*) pass "v3 without apk: hard-fail w/ actionable message" ;;
            *) fail "v3 error not actionable: $msg" ;;
        esac
    fi

    # The indexer must ALSO refuse (not silently skip) an unreadable v3 file.
    V3DIR="$TMP/v3dir"; mkdir -p "$V3DIR" "$TMP/feed-v3"
    cp "$ART/tollgate-wrt-0.5.0-r1-v3.apk" "$V3DIR/"
    if sh "$INDEX_FEED" "$V3DIR" "$TMP/feed-v3" >/dev/null 2>&1; then
        fail "index-feed must hard-fail on unreadable v3 artifact"
    else
        pass "index-feed hard-fails on unreadable v3 artifact"
    fi
fi

# Real-artifact smoke (skipped when the FD3-built APKv3 sample is absent):
# documents that a REAL 25.12 SDK package is v3 and — without apk-tools3 on
# this host — is refused cleanly rather than mis-indexed.
REAL_APK=${REAL_APK:-/home/c03rad0r/sdk-out/mediatek-filogic/tollgate-wrt-0.6.0_alpha1-r1.apk}
if [ -f "$REAL_APK" ]; then
    if [ "$(head -c 4 "$REAL_APK")" = "ADBd" ]; then
        pass "real FD3 artifact confirmed APKv3 (ADBd magic)"
        if sh "$ART_PROBE" "$REAL_APK" >/dev/null 2>&1; then
            fail "real v3 artifact must fail without native apk (unexpected pass!)"
        else
            pass "real v3 artifact refused cleanly (needs apk-tools3: SDK-container/CI path)"
        fi
    else
        fail "real FD3 artifact is NOT ADBd — assumptions changed, revisit tests"
    fi
else
    echo "  (real FD3 artifact not present — smoke skipped)"
fi

# ---------------------------------------------------------------------------
# 6. APKv3 index generation contract: apk-tools3 mkndx -> packages.adb
# ---------------------------------------------------------------------------
# MEASURED FACTS (2026-09-21, first-hand, this host):
#   - OpenWrt 25.12.5 SDK-built packages are APKv3 ("ADBd" magic).
#   - apk-tools3's `index` applet REJECTS v3 inputs
#     ("file format not supported (in this applet)") and — worse — when
#     handed RELATIVE paths it prints "WARNING: File ... is unaccessible"
#     and silently emits an EMPTY index (0 packages, 138 bytes). A feed
#     must never publish that: every index generator invocation below is
#     asserted to (a) use absolute paths, (b) index v3 via `mkndx` into
#     packages.adb (the index format apk-tools3 consumers read; the
#     official 25.12.5 feed serves packages.adb — APKINDEX.tar.gz/Packages.gz
#     are 404 there), and (c) hard-fail when the tool reports 0 packages.
#   - The OpenWrt SDK container ships apk-tools3 at
#     /builder/staging_dir/host/bin — NOT on PATH (probe: "apk: not found")
#     — build-feed.yml must add that dir to PATH.
#
# The stub `apk` below pins the generator <-> tool contract without
# needing a real SDK on every test host; the real toolchain is exercised
# by the CI `index` job and by the consumption test in the PR.

echo "== 6. APKv3 index generation (mkndx -> packages.adb, guards) =="

GEN_APK="$ROOT/scripts/generate-apk-index.sh"
V3FIX="$ART/tollgate-wrt-0.5.0-r1-v3.apk"   # created in section 5

# 6a. v3 without any apk on PATH: generator must hard-fail with an
#     actionable message (conditional — hosts/CI with native apk take
#     the delegated path tested via the stub below).
if ! command -v apk >/dev/null 2>&1; then
    V3SOLO="$TMP/v3solo"; mkdir -p "$V3SOLO"
    cp "$V3FIX" "$V3SOLO/"
    if sh "$GEN_APK" "$V3SOLO" "$V3SOLO" >/dev/null 2>&1; then
        fail "generate-apk-index v3 w/o apk must exit non-zero"
    else
        msg=$(sh "$GEN_APK" "$V3SOLO" "$V3SOLO" 2>&1 || true)
        case "$msg" in
            *APKv3*|*apk-tools3*|*SDK*) pass "v3 w/o apk: actionable hard-fail" ;;
            *) fail "v3 w/o apk message not actionable: $msg" ;;
        esac
    fi
else
    echo "  (native apk present — 6a no-apk sub-case skipped)"
fi

# 6b. v2 with a broken .PKGINFO, no apk: manual fallback must ABORT on
#     the unreadable artifact, not skip it and publish a partial index.
if ! command -v apk >/dev/null 2>&1; then
    V2BAD="$TMP/v2bad"; mkdir -p "$V2BAD" "$TMP/v2bad-out"
    printf 'not a tarball' > "$V2BAD/broken.apk"
    if sh "$GEN_APK" "$V2BAD" "$TMP/v2bad-out" >/dev/null 2>&1; then
        fail "v2 unreadable .PKGINFO must abort (got silent partial index)"
    else
        pass "v2 unreadable .PKGINFO aborts"
    fi
else
    echo "  (native apk present — 6b no-apk sub-case skipped)"
fi

# Stub apk-tools3: records invocations, emits the real output format
# ("Index has N packages (of which N are new)"), honors STUB_COUNT.
STUBBIN="$TMP/stubbin"; mkdir -p "$STUBBIN"
STUB_LOG="$TMP/stub.log"; export STUB_LOG
cat > "$STUBBIN/apk" <<'STUB'
#!/bin/sh
case "$1" in
--version) echo "apk-tools 3.0.5 (test stub)"; exit 0 ;;
adbdump)
    shift
    echo '{"name":"tollgate-wrt","arch":"aarch64_cortex-a53"}'
    exit 0 ;;
index|mkndx)
    cmd="$1"; shift
    out=""; files=""; flags=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --output|--description)
                       case "$1" in --output) out="$2" ;; esac; shift 2 ;;
            --*)       flags="${flags:+$flags }$1"; shift ;;
            *)         files="${files:+$files }$1"; shift ;;
        esac
    done
    # Record flags AND inputs on one line: `files=` is followed directly by
    # the (space-joined) absolute input paths so section 6c can assert both
    # that the flags reached the tool and that the paths are absolute.
    { printf 'cmd=%s out=%s files=%s flags=%s\n' "$cmd" "$out" "$files" "$flags"; } >> "${STUB_LOG:?}"
    n=$(printf '%s\n' "$files" | tr ' ' '\n' | grep -c '\.apk$' || true)
    [ -z "${STUB_COUNT:-}" ] || n="$STUB_COUNT"
    echo "Index has $n packages (of which $n are new)"
    if [ "$cmd" = "mkndx" ]; then
        printf 'ADBd-STUB packages=%s\n' "$n" > "$out"
    else
        d=$(mktemp -d)
        : > "$d/APKINDEX"
        [ "$n" -gt 0 ] && printf 'P:stub-pkg\n\n' > "$d/APKINDEX"
        printf 'stub feed\n' > "$d/DESCRIPTION"
        ( cd "$d" && tar -czf "$out" APKINDEX DESCRIPTION )
        rm -rf "$d"
    fi
    exit 0 ;;
*) echo "stub apk: unexpected subcommand: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUBBIN/apk"

# From here on the stub shadows any real apk, making sections below
# deterministic on every host (and in the CI container).
PATH="$STUBBIN:$PATH"; export PATH

# 6c. v3 + stub: mkndx is used, output is packages.adb, args carry
#     --allow-untrusted and ABSOLUTE paths, exit 0.
V3NDX="$TMP/v3ndx"; rm -rf "$V3NDX"; mkdir -p "$V3NDX" "$TMP/v3ndx-out"
cp "$V3FIX" "$V3NDX/"
: > "$STUB_LOG"
if sh "$GEN_APK" "$V3NDX" "$TMP/v3ndx-out" >/dev/null 2>&1; then
    [ -f "$TMP/v3ndx-out/packages.adb" ] \
        && pass "v3 -> packages.adb generated" \
        || fail "v3 did not produce packages.adb"
    [ ! -f "$TMP/v3ndx-out/APKINDEX.tar.gz" ] \
        && pass "v3 does not emit legacy APKINDEX.tar.gz" \
        || fail "v3 emitted legacy APKINDEX.tar.gz"
    grep -q '^cmd=mkndx ' "$STUB_LOG" \
        && pass "v3 uses mkndx applet" \
        || fail "v3 not routed to mkndx"
    grep -q ' --allow-untrusted' "$STUB_LOG" 2>/dev/null || \
    grep -qE 'allow-untrusted' "$STUB_LOG" \
        && pass "mkndx invoked with --allow-untrusted" \
        || fail "mkndx missing --allow-untrusted (log: $(cat "$STUB_LOG"))"
    case "$(grep '^cmd=mkndx ' "$STUB_LOG" | tail -n1)" in
        *"out=$TMP/v3ndx-out/packages.adb"*) pass "mkndx --output is absolute" ;;
        *) fail "mkndx --output not absolute: $(grep '^cmd=mkndx ' "$STUB_LOG")" ;;
    esac
    case "$(sed -n 's/^cmd=mkndx out=[^ ]* files=//p' "$STUB_LOG" | tail -n1)" in
        /*) pass "mkndx file args are absolute" ;;
        *) fail "mkndx file args not absolute: $(cat "$STUB_LOG")" ;;
    esac
else
    fail "generate-apk-index v3+stub must exit 0 (got failure)"
    sed -n 's/^/    /p' "$STUB_LOG" 2>/dev/null
fi

# 6d. EMPTY-INDEX GUARD: the tool reporting 0 packages for 1+ inputs is
#     a hard error — an empty index must never be published.
rm -rf "$TMP/v3ndx-out"; mkdir -p "$TMP/v3ndx-out"
STUB_COUNT=0 sh "$GEN_APK" "$V3NDX" "$TMP/v3ndx-out" >/dev/null 2>&1 \
    && fail "v3 mkndx count=0 must hard-fail" \
    || pass "v3 mkndx count=0 hard-fails (empty-index guard)"

# 6e. Same guard on the legacy v2 `index` path.
V2DIR="$TMP/v2only"; rm -rf "$V2DIR" "$TMP/v2-out"; mkdir -p "$V2DIR" "$TMP/v2-out"
make_apk "$V2DIR/tollgate-wrt-0.5.0-r1.apk" tollgate-wrt 0.5.0-r1 x86_64
STUB_COUNT=0 sh "$GEN_APK" "$V2DIR" "$TMP/v2-out" >/dev/null 2>&1 \
    && fail "v2 index count=0 must hard-fail" \
    || pass "v2 index count=0 hard-fails (empty-index guard)"
rm -rf "$TMP/v2-out"; mkdir -p "$TMP/v2-out"
if sh "$GEN_APK" "$V2DIR" "$TMP/v2-out" >/dev/null 2>&1; then
    [ -f "$TMP/v2-out/APKINDEX.tar.gz" ] \
        && pass "v2 -> APKINDEX.tar.gz generated" \
        || fail "v2 did not produce APKINDEX.tar.gz"
    tar -xzOf "$TMP/v2-out/APKINDEX.tar.gz" APKINDEX 2>/dev/null | grep -q '^P:' \
        && pass "v2 APKINDEX has a package record" \
        || fail "v2 APKINDEX has no P: record"
else
    fail "generate-apk-index v2+stub must exit 0"
fi

# 6f. index-feed.sh end-to-end with a v3 artifact + stub apk: the run
#     succeeds and lands packages.adb under the arch-tuple dir.
V3E2E="$TMP/v3e2e"; rm -rf "$V3E2E" "$TMP/feed-v3e2e"; mkdir -p "$V3E2E"
cp "$V3FIX" "$V3E2E/"
if sh "$INDEX_FEED" "$V3E2E" "$TMP/feed-v3e2e" >/dev/null 2>&1; then
    [ -f "$TMP/feed-v3e2e/aarch64_cortex-a53/packages.adb" ] \
        && pass "index-feed v3 -> <tuple>/packages.adb" \
        || fail "index-feed v3 missing <tuple>/packages.adb"
else
    fail "index-feed v3+stub must exit 0"
fi

# 6g. Workflow contract pins (build-feed.yml must be deployable as-is):
WF="$ROOT/.github/workflows/build-feed.yml"
grep -q 'staging_dir/host/bin' "$WF" \
    && pass "workflow puts SDK host apk-tools on PATH" \
    || fail "workflow missing PATH fix for host apk-tools"
grep -q "name 'packages.adb'" "$WF" \
    && pass "workflow index count includes packages.adb" \
    || fail "workflow index count misses packages.adb"
grep -q 'packages.adb|Packages' "$WF" || grep -q 'APKINDEX.tar.gz|Packages.gz|Packages|packages.adb' "$WF" \
    && pass "workflow release-flatten handles packages.adb" \
    || fail "workflow release-flatten misses packages.adb"

# ---------------------------------------------------------------------------
# 7. generate-packages-index.sh must abort on unreadable .ipk, not skip
# ---------------------------------------------------------------------------
# index-feed.sh is safe (artifact-arch.sh gates unreadable artifacts), but
# the opkg generator is also a standalone tool: a MIXED dir (one good, one
# corrupt .ipk) used to index the good one and silently drop the corrupt
# one — a partial feed published as success. It must abort instead.

echo "== 7. opkg generator: unreadable .ipk aborts (no silent partial feed) =="

GEN_IPK="$ROOT/scripts/generate-packages-index.sh"
IPKMIX="$TMP/ipkmix"; rm -rf "$IPKMIX" "$TMP/ipk-out"; mkdir -p "$IPKMIX" "$TMP/ipk-out"
make_ipk "$IPKMIX/good.ipk" tollgate-wrt 0.5.0-r1 x86_64
printf 'garbage not an ar archive' > "$IPKMIX/corrupt.ipk"
if sh "$GEN_IPK" "$IPKMIX" "$TMP/ipk-out" >/dev/null 2>&1; then
    fail "opkg generator must abort on corrupt .ipk (published partial index)"
else
    msg=$(sh "$GEN_IPK" "$IPKMIX" "$TMP/ipk-out" 2>&1 || true)
    case "$msg" in
        *corrupt.ipk*) pass "opkg generator aborts naming the corrupt artifact" ;;
        *) fail "opkg abort message lacks artifact name: $msg" ;;
    esac
fi

# ---------------------------------------------------------------------------

echo ""
if [ "$fails" -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "$fails test(s) FAILED"
exit 1
