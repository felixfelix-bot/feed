#!/bin/sh
# index-feed.sh — orchestrate opkg + apk index generation for all architectures
#
# Given a directory of built .ipk/.apk artifacts (mixed architectures), detect
# each file's architecture from its embedded control/.PKGINFO metadata, group
# the files by architecture, and run the opkg (generate-packages-index.sh) and
# apk (generate-apk-index.sh) index generators once per architecture.
#
# This is the entry point invoked by CI (.github/workflows/build-feed.yml) on
# every release. It exists so the workflow stays thin and the grouping logic is
# testable locally without GitHub Actions.
#
# Usage:
#   index-feed.sh <artifact-dir> <output-dir>
#
#     artifact-dir  Directory containing *.ipk and/or *.apk files (mixed arches)
#     output-dir    Root of the generated feed tree
#
# Output layout under <output-dir> (one subdir per architecture that had at
# least one artifact):
#
#   <output-dir>/<arch>/Packages         (opkg, uncompressed — kept for debugging)
#   <output-dir>/<arch>/Packages.gz      (opkg feed index)
#   <output-dir>/<arch>/APKINDEX.tar.gz  (apk feed index)
#
# Architectures are NOT hard-coded: whatever arches the artifacts declare are
# the arches that get indexed. An arch with only .ipk files gets only a
# Packages.gz; an arch with only .apk files gets only an APKINDEX.tar.gz.
#
# Exit codes:
#   0  success — at least one index generated, OR no artifacts present at all
#               (an empty release is not a failure)
#   1  usage error, missing dependency, or an index generator failed
#
# Part of the Freedom Tech Feed CI pipeline.

set -eu

err() {
    echo "ERROR: $*" >&2
}

ARTIFACT_DIR="${1:-}"
OUTPUT_DIR="${2:-}"

if [ -z "$ARTIFACT_DIR" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: $0 <artifact-dir> <output-dir>" >&2
    exit 1
fi
[ -d "$ARTIFACT_DIR" ] || { err "artifact dir not found: $ARTIFACT_DIR"; exit 1; }

# Resolve sibling generator scripts relative to this file.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OPKG_GEN="$SCRIPT_DIR/generate-packages-index.sh"
APK_GEN="$SCRIPT_DIR/generate-apk-index.sh"
[ -r "$OPKG_GEN" ] || { err "missing opkg generator: $OPKG_GEN"; exit 1; }
[ -r "$APK_GEN" ]  || { err "missing apk generator: $APK_GEN"; exit 1; }

for dep in ar tar gzip sha256sum sha1sum find; do
    command -v "$dep" >/dev/null 2>&1 || { err "missing required tool: $dep"; exit 1; }
done

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Architecture detection delegates to artifact-arch.sh — the single source
# of parsing truth (shared with the release bridge): .ipk via ar/control,
# .apk APKv2 via .PKGINFO, .apk APKv3 (ADBd, OpenWrt 25.12+) via native
# apk-tools3. An artifact whose arch cannot be read is a HARD failure —
# skipping it would silently publish an incomplete/empty feed.

# ---------------------------------------------------------------------------
# Group artifacts into staging/<arch>/{opkg,apk}/
# ---------------------------------------------------------------------------

echo "==> scanning $ARTIFACT_DIR for .ipk/.apk artifacts"

find "$ARTIFACT_DIR" -maxdepth 1 -type f \( -name '*.ipk' -o -name '*.apk' \) \
    | sort > "$WORK/files"

ipk_total=0
apk_total=0
while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in
        *.ipk)
            if ! arch=$(sh "$SCRIPT_DIR/artifact-arch.sh" "$f" 2>/dev/null); then
                err "could not read Architecture from $(basename "$f") — aborting (an unreadable artifact must block publication)"
                exit 1
            fi
            dest="$WORK/$arch/opkg"
            mkdir -p "$dest"
            ln "$f" "$dest/" 2>/dev/null || cp "$f" "$dest/"
            ipk_total=$((ipk_total + 1))
            echo "  ipk  [$arch] $(basename "$f")"
            ;;
        *.apk)
            if ! arch=$(sh "$SCRIPT_DIR/artifact-arch.sh" "$f" 2>/dev/null); then
                err "could not read arch from $(basename "$f") — aborting (an unreadable artifact must block publication; APKv3/ADBd files need apk-tools3 in PATH, e.g. an OpenWrt SDK container)"
                exit 1
            fi
            dest="$WORK/$arch/apk"
            mkdir -p "$dest"
            ln "$f" "$dest/" 2>/dev/null || cp "$f" "$dest/"
            apk_total=$((apk_total + 1))
            echo "  apk  [$arch] $(basename "$f")"
            ;;
    esac
done < "$WORK/files"

echo "==> grouped $ipk_total ipk + $apk_total apk artifact(s)"

# Bail out cleanly on an empty release — not an error condition.
if [ "$ipk_total" -eq 0 ] && [ "$apk_total" -eq 0 ]; then
    echo "==> no .ipk/.apk artifacts found; nothing to index (exit 0)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Run the generators per architecture. Hardlinks keep .ipk/.apk alongside the
# generated index in the output tree so the feed is self-contained.
# ---------------------------------------------------------------------------

indexed=0
for archdir in "$WORK"/*/; do
    [ -d "$archdir" ] || continue
    arch=$(basename "$archdir")
    out="$OUTPUT_DIR/$arch"
    mkdir -p "$out"

    # opkg/apk resolve "Filename" relative to the index file, so artifacts must
    # live flat in <arch>/ next to Packages.gz / APKINDEX.tar.gz (matches the
    # feed layout documented in docs/feed-strategy.md, Option A).
    has_ipk=0
    for ipk in "$archdir/opkg"/*.ipk; do
        [ -f "$ipk" ] || continue
        cp "$ipk" "$out/"
        has_ipk=1
    done
    has_apk=0
    for apk in "$archdir/apk"/*.apk; do
        [ -f "$apk" ] || continue
        cp "$apk" "$out/"
        has_apk=1
    done

    # Both generators run on the same flat dir: the opkg one globs *.ipk, the
    # apk one globs *.apk, so they ignore each other's artifacts. Invoked via
    # `sh` so correctness does not depend on the committed execute-bit.
    if [ "$has_ipk" -eq 1 ]; then
        echo "==> opkg index: $arch"
        sh "$OPKG_GEN" "$out" "$out" || { err "opkg index failed for $arch"; exit 1; }
        indexed=$((indexed + 1))
    fi
    if [ "$has_apk" -eq 1 ]; then
        echo "==> apk index: $arch"
        sh "$APK_GEN" "$out" "$out" || { err "apk index failed for $arch"; exit 1; }
        indexed=$((indexed + 1))
    fi
    # generate-apk-index.sh leaves a .tmp scratch dir; remove it.
    rm -rf "$out/.tmp"
done

echo ""
echo "==> done: $indexed index/indices generated under $OUTPUT_DIR"
find "$OUTPUT_DIR" -maxdepth 2 \( -name 'Packages.gz' -o -name 'APKINDEX.tar.gz' \) -type f \
    | sort | while IFS= read -r p; do
        printf '   %s  (%s bytes)\n' "$p" "$(wc -c < "$p")"
    done
