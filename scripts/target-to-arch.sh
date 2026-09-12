#!/bin/sh
# target-to-arch.sh — map an OpenWrt SDK *target* name to its arch TUPLE
#
# The build-sdk CI matrix is per TARGET (x86-64, mediatek-filogic,
# ramips-mt7621, ...) because SDK images are published per target. Feed
# consumers, however, key their feed URLs on arch TUPLES
# (x86_64, aarch64_cortex-a53, mipsel_24kc, ...) — the tuple is what the
# built .apk/.ipk declares in .PKGINFO / control and what the feed
# directory layout uses. The release-bridge job in
# .github/workflows/build-feed.yml calls this script to name release
# assets with the tuple, then cross-checks the artifact's EMBEDDED arch
# against it (mismatch = hard failure, no silent mispublication).
#
# Usage:   target-to-arch.sh <target>
# Prints:  the arch tuple on stdout, exit 0
#          unknown target: exit 1 with a message on stderr
#
# To add a target: append a line to the case below. The tuple MUST match
# the arch the SDK for that target stamps into packages (verify with:
# tar -xzOf pkg.apk .PKGINFO | grep '^arch = ').

set -eu

target="${1:-}"
[ -n "$target" ] || { echo "usage: $0 <target>" >&2; exit 1; }

case "$target" in
    x86-64)              echo "x86_64" ;;
    x86-64-v2)           echo "x86_64_v2" ;;
    mediatek-filogic)    echo "aarch64_cortex-a53" ;;
    mediatek-mt7622)     echo "aarch64_cortex-a53" ;;
    ramips-mt7621)       echo "mipsel_24kc" ;;
    ath79-generic)       echo "mips_24kc" ;;
    mvebu-cortexa9)      echo "arm_cortex-a9_vfpv3" ;;
    ipq40xx-generic)     echo "arm_cortex-a7_neon-vfpv4" ;;
    *)
        echo "ERROR: unknown OpenWrt target '$target' — add it to scripts/target-to-arch.sh (tuple must match the arch stamped into the built .apk/.ipk)" >&2
        exit 1
        ;;
esac
