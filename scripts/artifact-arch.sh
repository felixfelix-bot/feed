#!/bin/sh
# artifact-arch.sh — print the OpenWrt arch TUPLE embedded in a package file
#
# Reads the arch straight out of the artifact's own metadata:
#   .apk  -> first `arch = <tuple>` line of the .PKGINFO tar member
#   .ipk  -> `Architecture: <tuple>` field of the ar control.tar member
#
# Used by the release-bridge job (build-feed.yml) together with
# target-to-arch.sh to verify that a workflow artifact built for SDK
# target T really stamps the tuple we expect for T — a mismatch fails
# the bridge before anything is published.
#
# Usage:   artifact-arch.sh <file.apk|file.ipk>
# Prints:  the arch tuple, exit 0
# Errors:  unreadable file / no arch found -> exit 1

set -eu

f="${1:-}"
[ -n "$f" ] || { echo "usage: $0 <file.apk|file.ipk>" >&2; exit 1; }
[ -f "$f" ] || { echo "ERROR: not a file: $f" >&2; exit 1; }

arch=""

case "$f" in
    *.apk)
        arch=$(tar -xzOf "$f" .PKGINFO 2>/dev/null \
            | sed -n 's/^arch[[:space:]]*=[[:space:]]*//p' \
            | head -n1 | tr -d '[:space:]')
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
        ;;
    *)
        echo "ERROR: unknown package type (need .apk or .ipk): $f" >&2
        exit 1
        ;;
esac

[ -n "$arch" ] || { echo "ERROR: could not read arch from $f" >&2; exit 1; }
printf '%s\n' "$arch"
