#!/bin/sh
# sync-from-upstream.sh — re-pin the feed to a given upstream
# tollgate-module-basic-go release tag.
#
# Usage:
#   scripts/sync-from-upstream.sh <tag>      # e.g. v0.6.0-alpha1
#   scripts/sync-from-upstream.sh 0.6.0-alpha1   # leading 'v' is optional
#
# What it does:
#   1. Downloads the source tarball for <tag> from codeload.github.com.
#   2. Computes its sha256 and updates PKG_HASH in net/tollgate-wrt/Makefile.
#   3. Sets PKG_SOURCE_VERSION (the hyphenated upstream git tag — drives the
#      download URL and the tag-named build dirs).
#   4. Sets PKG_VERSION (the apk-legal package version: hyphens mapped to
#      underscores, because apk-tools 3.x rejects hyphens).
#   5. Sanity-checks that the tarball still ships packaging/files/ — the
#      runtime files (init.d, uci-defaults, captive-portal site, ...) are
#      installed from there at build time and are NOT vendored into this
#      feed anymore, so a release bump pulls them in automatically.
#
# After running, review the diff and commit. The runtime files themselves
# need no sync step; the validate-feed.yml CI verifies that every
# packaging/files/ path the Makefile references exists in the pinned
# tarball.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAKEFILE="$REPO_ROOT/net/tollgate-wrt/Makefile"
UPSTREAM="OpenTollGate/tollgate-module-basic-go"

TAG="${1:-}"
if [ -z "$TAG" ]; then
	echo "Usage: $0 <tag>   (e.g. v0.6.0-alpha1)" >&2
	exit 1
fi

# PKG_SOURCE_VERSION keeps the upstream tag's hyphens; PKG_VERSION is the
# apk-legal form with hyphens mapped to underscores (0.6.0-alpha1 ->
# 0.6.0_alpha1).
PKG_SOURCE_VERSION="${TAG#v}"
PKG_VERSION="$(printf '%s' "$PKG_SOURCE_VERSION" | tr '-' '_')"
URL="https://codeload.github.com/${UPSTREAM}/tar.gz/v${PKG_SOURCE_VERSION}"

for dep in curl tar sha256sum; do
	command -v "$dep" >/dev/null 2>&1 || { echo "ERROR: missing tool: $dep" >&2; exit 1; }
done
[ -f "$MAKEFILE" ] || { echo "ERROR: $MAKEFILE not found" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Downloading $URL"
TARBALL="$WORK/source.tar.gz"
curl -fsSL -o "$TARBALL" "$URL"
HASH="$(sha256sum "$TARBALL" | awk '{print $1}')"
echo "==> sha256 = $HASH"

echo "==> Verifying packaging/files/ is present in the tarball"
mkdir -p "$WORK/extract"
tar -xzf "$TARBALL" -C "$WORK/extract"
SRC_FILES="$WORK/extract/${UPSTREAM#*/}-${PKG_SOURCE_VERSION}/packaging/files"
if [ ! -d "$SRC_FILES" ]; then
	echo "ERROR: packaging/files/ not found in tarball (looked for $SRC_FILES)" >&2
	echo "       Has the upstream layout changed?" >&2
	exit 1
fi
find "$SRC_FILES" -type f | wc -l | awk '{printf "    %d runtime files ship in the tarball\n", $1}'

echo "==> Updating Makefile (PKG_VERSION=$PKG_VERSION, PKG_SOURCE_VERSION=$PKG_SOURCE_VERSION, PKG_HASH=$HASH)"
sed -i \
	-e "s|^PKG_VERSION:.*|PKG_VERSION:=$PKG_VERSION|" \
	-e "s|^PKG_SOURCE_VERSION:.*|PKG_SOURCE_VERSION:=$PKG_SOURCE_VERSION|" \
	-e "s|^PKG_HASH:.*|PKG_HASH:=$HASH|" \
	"$MAKEFILE"

echo
echo "Done. Review with:  git -C \"$REPO_ROOT\" diff"
echo "Runtime files ride along in the tarball — nothing to re-vendor."
echo "Then build-validate via the validate-feed.yml CI (SDK job)."
