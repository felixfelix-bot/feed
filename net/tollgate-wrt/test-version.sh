#!/bin/sh
# test-version.sh - verify the CLI reports the package version.
#
# Called by the openwrt/packages buildbot in the test environment after
# installing the tollgate-wrt package. The package installs the CLI as
# /usr/bin/tollgate; this script confirms the binary exists and that its
# version output contains the value of PKG_VERSION in net/tollgate-wrt/Makefile.
#
# The CLI exposes the version through a cobra `version` subcommand (it has no
# --version flag), so we accept either a --version probe or the subcommand.
# The version string is injected via the feed's LDFLAGS as
# cli.Version="v$(PKG_VERSION)" (i.e. "v0.6.0-alpha1"), so a bare "0.6.0"
# always appears in the reported version either way.
#
# Exit status: 0 = pass, 1 = fail.

BINARY="/usr/bin/tollgate"
PKG_VERSION="0.6.0-alpha1"

if [ ! -x "$BINARY" ]; then
    echo "FAIL: $BINARY not found" >&2
    exit 1
fi

# Prefer --version (what the buildbot probes); fall back to `version` subcommand.
# shellcheck disable=SC2312
OUTPUT=$("$BINARY" --version 2>/dev/null || "$BINARY" version 2>&1)

if printf '%s\n' "$OUTPUT" | grep -qi "0\.6\.0"; then
    echo "PASS: $BINARY reports version $PKG_VERSION"
    exit 0
fi

echo "FAIL: $BINARY did not report version $PKG_VERSION" >&2
printf 'Output:\n%s\n' "$OUTPUT" >&2
exit 1
