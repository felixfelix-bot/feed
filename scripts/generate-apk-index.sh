#!/bin/sh
# generate-apk-index.sh
#
# Generate an apk repository index from a directory of .apk files.
#
# Usage:  generate-apk-index.sh <apk-dir> [output-dir]
#   apk-dir    Directory containing *.apk files
#   output-dir Where to write the index (default: apk-dir)
#
# Which index file is produced depends on the INPUT format (detected per
# file via magic bytes) and on which `apk` is available:
#
#   APKv3 (ADBd — OpenWrt 25.12+ SDK output)  -> packages.adb via `apk mkndx`
#   APKv2 (tar.gz with .PKGINFO)              -> APKINDEX.tar.gz via `apk index`
#
# Both are hard-fail-loud paths:
#   - v3 files REQUIRE a native apk-tools3 (`index` cannot read v3:
#     "file format not supported (in this applet)" — measured 2026-09-21
#     against apk-tools 3.0.5/3.0.8; worse, with relative paths `index`
#     prints "WARNING: ... unaccessible" and emits an EMPTY index).
#   - ALL paths passed to the native apk are ABSOLUTE (see above).
#   - If the tool reports fewer indexed packages than there are inputs,
#     that is a hard error: an empty/partial index must never publish.
#
# The v3 path is why CI's `index` job runs inside the OpenWrt SDK
# container (host apk-tools at /builder/staging_dir/host/bin — the
# target-rootfs apk is NOT on the container PATH).
#
#   packages.adb is the index apk-tools3 consumers fetch (OpenWrt's
#   official 25.12.5 feed serves packages.adb; APKINDEX.tar.gz 404s).
#   v2 targets (24.10 era) read APKINDEX.tar.gz, so v2 inputs keep it.
#
# See docs/feed-index.md.
set -eu

usage() {
    echo "Usage: $0 <apk-dir> [output-dir]" >&2
    exit 2
}

[ $# -ge 1 ] || usage
APK_DIR=$1
OUT_DIR=${2:-$APK_DIR}

[ -d "$APK_DIR" ] || { echo "error: apk dir '$APK_DIR' not found" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# Use a tmpdir under OUT_DIR so the script works even when system /tmp is full.
export TMPDIR="$OUT_DIR/.tmp"
mkdir -p "$TMPDIR"

# Absolutize both dirs (native apk mis-handles relative paths silently).
APK_DIR=$(cd "$APK_DIR" && pwd)
OUT_DIR=$(cd "$OUT_DIR" && pwd)

# Collect apk files (sorted for determinism; absolute paths).
apks=$(find "$APK_DIR" -maxdepth 1 -type f -name '*.apk' | sort)
apk_count=$(printf '%s\n' "$apks" | grep -c '\.apk$' || true)

if [ "$apk_count" -eq 0 ]; then
    echo "warning: no .apk files in '$APK_DIR' — generating empty index" >&2
fi

# Classify inputs by magic bytes.
v3_files=""
v2_files=""
for a in $apks; do
    [ -f "$a" ] || continue
    if [ "$(head -c 4 "$a" 2>/dev/null || true)" = "ADBd" ]; then
        v3_files="$v3_files $a"
    else
        v2_files="$v2_files $a"
    fi
done
v3_count=$(printf '%s' "$v3_files" | wc -w | tr -d ' ')
v2_count=$(printf '%s' "$v2_files" | wc -w | tr -d ' ')

# ---------------------------------------------------------------------------
# Empty-index guard, shared by both native paths: the tool's own "Index
# has N packages" report is the truth — if it indexed fewer packages than
# there are input files, abort (never publish a silently-truncated index;
# a real trigger is apk-tools3's relative-path "unaccessible" WARNING).
# ---------------------------------------------------------------------------
assert_indexed_all() { # <expected-count> <tool-output>
    expected=$1; report=$2
    got=$(printf '%s\n' "$report" | sed -n 's/^Index has \([0-9][0-9]*\) packages.*/\1/p' | head -n1)
    [ -n "$got" ] || got=0
    if [ "$got" -lt "$expected" ]; then
        echo "ERROR: apk indexed $got package(s) but $expected input(s) were present — refusing to publish a partial/empty index. (Relative paths and unreadable inputs make apk-tools3 silently skip files: always pass ABSOLUTE paths; check the WARNING lines above.)" >&2
        exit 1
    fi
}

if command -v apk >/dev/null 2>&1; then
    # ---------------------------------------------------------------- strategy 1
    if [ "$v3_count" -gt 0 ]; then
        echo "==> using native 'apk mkndx' ($v3_count APKv3 input(s))" >&2
        # CI artifacts are unsigned: --allow-untrusted is required to index
        # them (mirrors apk-tools' own flag for local index building).
        # shellcheck disable=SC2086
        report=$(apk mkndx \
            --allow-untrusted \
            --output "$OUT_DIR/packages.adb" \
            $v3_files 2>&1) || { echo "$report" >&2; echo "ERROR: apk mkndx failed" >&2; exit 1; }
        printf '%s\n' "$report" >&2
        assert_indexed_all "$v3_count" "$report"
        echo "==> wrote $OUT_DIR/packages.adb (apk mkndx, $v3_count packages)" >&2
    fi
    if [ "$v2_count" -gt 0 ]; then
        echo "==> using native 'apk index' ($v2_count APKv2 input(s))" >&2
        # apk index writes the tarball index for APKv2 (24.10-era consumers).
        # shellcheck disable=SC2086
        report=$(apk index \
            --output "$OUT_DIR/APKINDEX.tar.gz" \
            --description "tollgate feed" \
            $v2_files 2>&1) || { echo "$report" >&2; echo "ERROR: apk index failed" >&2; exit 1; }
        printf '%s\n' "$report" >&2
        assert_indexed_all "$v2_count" "$report"
        echo "==> wrote $OUT_DIR/APKINDEX.tar.gz (apk index, $v2_count packages)" >&2
    fi
    [ "$((v3_count + v2_count))" -gt 0 ] || exit 0
    exit 0
fi

# ---------------------------------------------------------------------------
# No native apk: v3 is impossible (fail loudly, actionable), v2 falls back
# to the POSIX parser below.
# ---------------------------------------------------------------------------
if [ "$v3_count" -gt 0 ]; then
    for a in $v3_files; do
        echo "error: $(basename "$a") is APKv3 (ADBd) and no native 'apk' is in PATH — cannot index. Use an OpenWrt SDK container (host apk-tools3 at /builder/staging_dir/host/bin) or pre-convert to v2." >&2
    done
    exit 1
fi

# ---------------------------------------------------------------- strategy 2
# Manual fallback for APKv2-only inputs. APKv2 packages are gzip-compressed
# tarballs whose first member is .PKGINFO, a list of `key = value` lines.
# We build an APKINDEX record per package using the documented flag
# prefixes. An unreadable package ABORTS the run — skipping it would
# silently publish a partial index.
#
# Reference flags (Alpine apk-tools):
#   P package name        V version          A arch
#   S .apk file size      I installed size   T deps (space-sep)
#   p provides            i install_if       k provider priority
#   D description         o origin           m maintainer
#   U file size (int)     t build timestamp  c commit hash
#   l license             u url
#
# Records are newline-separated by a blank line.
echo "==> 'apk index' not found; building APKINDEX manually (APKv2 only)" >&2

INDEX_FILE=$(mktemp)
DESC_FILE=$(mktemp)
trap 'rm -f "$INDEX_FILE" "$DESC_FILE"' EXIT

printf 'tollgate feed\n' > "$DESC_FILE"

indexed=0
for apk in $apks; do
    [ -f "$apk" ] || continue
    base=$(basename "$apk")
    size=$(wc -c < "$apk" | tr -d ' ')

    # Extract .PKGINFO member from the gzip tarball.
    pkginfo=$(tar -xzOf "$apk" .PKGINFO 2>/dev/null || true)
    if [ -z "$pkginfo" ]; then
        echo "error: $base has no readable .PKGINFO (not an APKv2 tarball?) — aborting; a partial index must not publish" >&2
        exit 1
    fi

    # Helper: read first value for a PKGINFO key.
    field() { printf '%s\n' "$pkginfo" | sed -n "s/^$1 = \\(.*\\)$/\\1/p" | head -n1; }

    name=$(field pkgname)
    ver=$(field pkgver)
    arch=$(field arch)
    deps=$(field depend)
    provides=$(field provides)
    install_if=$(field install_if)
    origin=$(field origin)
    maint=$(field maintainer)
    license=$(field license)
    url=$(field url)
    desc=$(field pkgdesc)
    builddate=$(field builddate)
    isz=$(field size || true)
    commit=$(field commit || true)

    # SHA1 checksum of the apk file (lowercase hex) — apk index uses 'C' for it.
    csum=$(sha1sum "$apk" | awk '{print $1}')

    {
        [ -n "$csum" ]    && printf 'C:%s\n'    "$csum"
        [ -n "$name" ]    && printf 'P:%s\n'    "$name"
        [ -n "$ver" ]     && printf 'V:%s\n'    "$ver"
        [ -n "$arch" ]    && printf 'A:%s\n'    "$arch"
        printf 'S:%s\n' "$size"
        [ -n "$isz" ]     && printf 'I:%s\n'    "$isz"
        [ -n "$deps" ]    && printf 'T:%s\n'    "$deps"
        [ -n "$provides" ]  && printf 'p:%s\n' "$provides"
        [ -n "$install_if" ] && printf 'i:%s\n' "$install_if"
        [ -n "$desc" ]    && printf 'D:%s\n'    "$desc"
        [ -n "$url" ]     && printf 'u:%s\n'    "$url"
        [ -n "$license" ] && printf 'l:%s\n'   "$license"
        [ -n "$origin" ]  && printf 'o:%s\n'   "$origin"
        [ -n "$maint" ]   && printf 'm:%s\n'   "$maint"
        [ -n "$builddate" ] && printf 't:%s\n'  "$builddate"
        printf 'U:%s\n' "$size"
        [ -n "$commit" ]  && printf 'c:%s\n'  "$commit"
        printf '\n'
    } >> "$INDEX_FILE"
    indexed=$((indexed + 1))
done

# Empty-index guard for the manual path too (expected = inputs present).
if [ "$indexed" -lt "$apk_count" ]; then
    echo "error: manual indexer handled $indexed of $apk_count input(s) — aborting; a partial index must not publish" >&2
    exit 1
fi

# ---------------------------------------------------------------- tar+gzip
# APKINDEX.tar.gz is a gzip tarball containing APKINDEX and DESCRIPTION
# (plain files, not compressed individually).
tmp_tar=$(mktemp -d)
trap 'rm -rf "$tmp_tar"' EXIT
cp "$INDEX_FILE" "$tmp_tar/APKINDEX"
cp "$DESC_FILE"  "$tmp_tar/DESCRIPTION"

( cd "$tmp_tar" && tar -czf "$OUT_DIR/APKINDEX.tar.gz" APKINDEX DESCRIPTION )

echo "==> wrote $OUT_DIR/APKINDEX.tar.gz (manual, $indexed packages)" >&2