#!/bin/sh
# Smoke test for the tollgate-wrt package.
#
# openwrt/packages convention: <pkg>/test.sh runs on a target/emulated router
# after install; $1 = package name. Exit 0 on success, non-zero on failure.
# Verifies both binaries the package ships (the service and the CLI) are present
# as valid ELF executables and that the CLI responds to --help. The service is a
# long-running daemon, so it is NOT launched here (that belongs on a live router
# behind a procd service); we only prove the payload is sane.

case "$1" in
tollgate-wrt) ;;
*) exit 0 ;;
esac

SERVICE=/usr/bin/tollgate-wrt
CLI=/usr/bin/tollgate

for BIN in "$SERVICE" "$CLI"; do
	[ -x "$BIN" ] || { echo "FAIL: $BIN not installed or not executable"; exit 1; }
	file "$BIN" 2>/dev/null | grep -q "ELF" || { echo "FAIL: $BIN is not an ELF binary"; exit 1; }
done

# CLI must boot and answer --help (root subcommand). rc 0 = clean.
"$CLI" --help >/tmp/tollgate-cli-help 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: $CLI --help exited $rc"; exit 1; }

echo "tollgate-wrt: smoke test passed (service + CLI present, CLI responds)"
exit 0
