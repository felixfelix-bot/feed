#!/bin/sh
# artifact-arch.sh — print the OpenWrt arch TUPLE embedded in a package file
#
# Reads the arch straight out of the artifact's own metadata:
#   .apk APKv2 (tar.gz)  -> first `arch = <tuple>` line of .PKGINFO
#   .apk APKv3 (ADB)     -> parsed by native apk-tools3 (`apk adbdump`),
#                           see "APKv3" below
#   .ipk                 -> `Architecture: <tuple>` field of the control
#                           tar member inside the ar archive
#
# APKv3: OpenWrt 25.12 SDKs stamp packages in apk-tools3's ADB container
# format (magic bytes "ADBd") — NOT a tarball, and the arch is not
# recoverable with shell tools (the ADB string table is compressed).
# For those files this script REQUIRES a native `apk` binary in PATH
# (any OpenWrt SDK container has one) and delegates to `apk adbdump`.
# Without `apk`, a v3 file is a hard error — never a silent skip: an
# unreadable arch must block publication, not produce an empty feed.
#
# Used by the release pipeline (build-feed.yml) together with
# target-to-arch.sh to verify that a workflow artifact built for SDK
# target T really stamps the tuple expected for T.
#
# Usage:   artifact-arch.sh <file.apk|file.ipk>
# Prints:  the arch tuple, exit 0
# Errors:  unreadable file / no arch found / v3 without apk -> exit 1

set -eu

f="${1:-}"
[ -n "$f" ] || { echo "usage: $0 <file.apk|file.ipk>" >&2; exit 1; }
[ -f "$f" ] || { echo "ERROR: not a file: $f" >&2; exit 1; }

# An arch tuple we are willing to believe (whitelist: canonical OpenWrt
# tuples). Guards against parsing accidents returning garbage.
valid_tuple() {
    case "$1" in
        aarch64_cortex-a53|x86_64|x86_64_v2|mipsel_24kc|mips_24kc|\
        arm_cortex-a7_neon-vfpv4|arm_cortex-a9_vfpv3|arm_cortex-a15_neon-vfpv4|\
        aarch64_generic|riscv64|riscv64_gc_zbb) return 0 ;;
        *) return 1 ;;
    esac
}

emit() {
    if valid_tuple "$1"; then
        printf '%s\n' "$1"
        exit 0
    fi
    echo "ERROR: implausible arch tuple '$1' from $f" >&2
    exit 1
}

magic=$(head -c 4 "$f" 2>/dev/null || true)

case "$f" in
    *.apk)
        if [ "$magic" = "ADBd" ]; then
            # APKv3 — needs apk-tools3.
            if command -v apk >/dev/null 2>&1; then
                # apk adbdump emits UNQUOTED YAML (measured 2026-10-21,
                # apk-tools 3.0.8-r0): "  arch: aarch64_cortex-a53" under
                # "info:". Accept the unquoted form first, then a quoted
                # form for forward compat. Anchored ^\s*arch: so it cannot
                # match installed-size:/origin:/provides items.
                dump=$(apk adbdump "$f" 2>/dev/null || true)
                arch=$(printf '%s\n' "$dump" \
                    | sed -n 's/^[[:space:]]*arch:[[:space:]]*\([a-z0-9_.-]*\)[[:space:]]*$/\1/p' \
                    | head -n1)
                [ -n "$arch" ] || arch=$(printf '%s\n' "$dump" \
                    | sed -n 's/^[[:space:]]*arch:[[:space:]]*"\([a-z0-9_.-]*\)"[[:space:]]*$/\1/p' \
                    | head -n1)
                [ -n "$arch" ] || {
                    echo "ERROR: apk adbdump yielded no arch for $f (dump parse failed)" >&2
                    exit 1
                }
                emit "$arch"
            else
                echo "ERROR: $f is APKv3 (ADBd) — reading its arch requires apk-tools3. Run inside an OpenWrt SDK container (e.g. openwrt/sdk:x86-64-v25.12.5), which ships apk." >&2
                exit 1
            fi
        else
            # APKv2 — gzip tarball with .PKGINFO.
            arch=$(tar -xzOf "$f" .PKGINFO 2>/dev/null \
                | sed -n 's/^arch[[:space:]]*=[[:space:]]*//p' \
                | head -n1 | tr -d '[:space:]')
            [ -n "$arch" ] || { echo "ERROR: could not read arch from $f" >&2; exit 1; }
            emit "$arch"
        fi
        ;;
    *.ipk)
        d=$(mktemp -d)
        trap 'rm -rf "$d"' EXIT
        if ar x "$f" --output "$d" 2>/dev/null; then
            ctrl_tar=""
            for c in "$d"/control.tar.* "$d"/control.tar; do
                [ -f "$c" ] && { ctrl_tar="$c"; break; }
            done
            if [ -n "$ctrl_tar" ] && tar xf "$ctrl_tar" -C "$d" 2>/dev/null; then
                for cf in "$d/control" "$d/./control"; do
                    if [ -f "$cf" ]; then
                        arch=$(sed -n 's/^Architecture:[[:space:]]*//p' "$cf" \
                            | head -n1 | tr -d '[:space:]')
                        break
                    fi
                done
            fi
        fi
        [ -n "$arch" ] || { echo "ERROR: could not read arch from $f" >&2; exit 1; }
        emit "$arch"
        ;;
    *)
        echo "ERROR: unknown package type (need .apk or .ipk): $f" >&2
        exit 1
        ;;
esac
