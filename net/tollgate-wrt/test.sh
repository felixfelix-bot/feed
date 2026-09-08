#!/bin/sh
# test.sh - verify the tollgate-wrt package installs both binaries.
#
# Called by the openwrt/packages buildbot in the test environment after
# installing the tollgate-wrt package. The package is one unit that ships two
# binaries: the service (/usr/bin/tollgate-wrt) and the CLI (/usr/bin/tollgate).
# This script confirms both are present and executable.
#
# Exit status: 0 = pass, 1 = fail.

for bin in /usr/bin/tollgate-wrt /usr/bin/tollgate; do
    if [ ! -x "$bin" ]; then
        echo "FAIL: $bin not found" >&2
        exit 1
    fi
    echo "OK: $bin present"
done

echo "PASS: both binaries present"
exit 0
