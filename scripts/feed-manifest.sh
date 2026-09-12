#!/bin/bash
# =============================================================================
# feed-manifest.sh — record the BUILD job's artifact hashes (the publish contract)
# =============================================================================
#
# Run this in the SAME job that produced the packages, before anything is
# uploaded or copied. feed-publish.sh then refuses to index any file whose
# sha256 differs from what is recorded here — that is how "the publish step
# only downloads and indexes" becomes a checked fact instead of a promise.
#
# Usage:
#   feed-manifest.sh <artifact-dir> [--format apk|opkg] [--out FILE]
#
# stdout (or FILE):  "<sha256>  <filename>"   LC_ALL=C sorted, one per package.
# Exit: 1 if the directory holds no package of the requested format, or a
#       package filename is not immutable-versioned.
# =============================================================================
set -euo pipefail

FORMAT=apk
OUT=""
DIR=""

while [ $# -gt 0 ]; do
	case "$1" in
		--format) FORMAT=${2:?}; shift 2 ;;
		--out)    OUT=${2:?}; shift 2 ;;
		-h|--help) sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*) echo "unknown argument: $1" >&2; exit 1 ;;
		*)  DIR=$1; shift ;;
	esac
done

[ -n "$DIR" ] || { echo "usage: feed-manifest.sh <artifact-dir> [--format apk|opkg] [--out FILE]" >&2; exit 1; }
[ -d "$DIR" ] || { echo "FAIL: not a directory: $DIR" >&2; exit 1; }

case "$FORMAT" in
	apk)  ext=apk; re='^[A-Za-z0-9][A-Za-z0-9+._-]*-[0-9][A-Za-z0-9+._~-]*\.apk$' ;;
	opkg) ext=ipk; re='^[A-Za-z0-9][A-Za-z0-9+.-]*_[A-Za-z0-9._~+-]+_[A-Za-z0-9._-]+\.ipk$' ;;
	*) echo "FAIL: --format must be apk or opkg" >&2; exit 1 ;;
esac

mapfile -t files < <(cd "$DIR" && ls -1 ./*."$ext" 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort)
if [ "${#files[@]}" -eq 0 ]; then
	echo "FAIL: no .$ext packages in $DIR — refusing to write an empty manifest" >&2
	exit 1
fi

for f in "${files[@]}"; do
	if ! [[ "$f" =~ $re ]]; then
		echo "FAIL: '$f' is not immutable-versioned (expected one of the package managers' filename templates);" >&2
		echo "      a re-cut of the same version is invisible to 'apk upgrade' — bump PKG_RELEASE instead." >&2
		exit 1
	fi
done

emit() {
	printf '# build manifest for %s (*.%s) — generated %s\n' "$DIR" "$ext" "$(date -u +%FT%TZ)"
	(cd "$DIR" && sha256sum "${files[@]}")
}

if [ -n "$OUT" ]; then
	emit > "$OUT"
	cat "$OUT"
else
	emit
fi
