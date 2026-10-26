#!/bin/sh
# t_d41ef5b5: apk upgrade/del/pin semantics that §5.1 and §5.2 of
# docs/feed-consumption-install.md rely on. Run inside an OpenWrt 25.12.5 x86_64
# userland with the standard OpenWrt feeds reachable. `jq` stands in for
# tollgate-wrt: every assertion is about apk's own world-file and purge
# behaviour, not about the package under test.
set -u
. /etc/openwrt_release
echo "== environment =="
echo "release: $DISTRIB_DESCRIPTION"
echo "pkg mgr: $(apk --version)"

echo
echo "== P1  apk upgrade takes a package argument (the package-scoped form) =="
apk upgrade --help 2>&1 | sed -n '3p'
echo "--- apk upgrade <package that is not installed>:"
apk upgrade tollgate-wrt 2>&1 | tail -1
rc=$?
echo "shell rc after the pipe = $rc  (see P4 for what apk itself returns)"

echo
echo "== P2  apk update + apk add, and the world entry apk keeps =="
apk update >/tmp/u.log 2>&1; echo "update_exit=$?  $(tail -1 /tmp/u.log)"
apk add jq >/tmp/a.log 2>&1; echo "add_exit=$?   $(tail -1 /tmp/a.log)"
echo "--- world line for jq (unpinned install):"
grep -E '^jq' /etc/apk/world
echo "--- apk policy jq:"
apk policy jq 2>/dev/null | head -4

echo
echo "== P3  pinning in the world file (the rollback mechanism) =="
apk add 'jq=1.8.1-r2' >/tmp/p.log 2>&1; echo "pin_exit=$?  $(tail -1 /tmp/p.log)"
echo "--- world line after pinning:"
grep -E '^jq' /etc/apk/world
echo "--- apk policy jq after pinning (expect: UNCHANGED -- policy does not show"
echo "    the world pin, only the indexes' offers):"
apk policy jq 2>/dev/null | head -5
echo "--- ...so the pin is only visible in the world file:"
grep -E '^jq' /etc/apk/world

echo
echo "== P4  exit codes: script on output, not on \$? =="
apk upgrade tollgate-wrt >/tmp/np.out 2>/tmp/np.err
echo "apk upgrade <unknown package>: exit=$? stderr=$(cat /tmp/np.err)"
apk update >/tmp/nu.out 2>&1
echo "apk update with every repo reachable: exit=$?"

echo
echo "== P5  apk del purges the package but NOT operator-created files =="
mkdir -p /usr/share/jq
echo "operator-data" > /usr/share/jq/operator-notes.json
echo "before apk del: $(ls /usr/share/jq)"
apk del jq >/tmp/d.log 2>&1; echo "del_exit=$?  $(tail -1 /tmp/d.log)"
echo "--- world line for jq after del (expect: none):"
grep -E '^jq' /etc/apk/world || echo "  (no jq line: the world entry is gone)"
echo "--- what survives inside the package's own directory:"
ls -l /usr/share/jq 2>&1
echo "content: $(cat /usr/share/jq/operator-notes.json 2>&1)"
echo
echo "  => \`apk del\` removes exactly the files the index lists. Anything an"
echo "     operator put inside a package-owned directory survives, which is why"
echo "     removing tollgate-wrt does not delete /etc/tollgate/{config,install,"
echo "     identities}.json or ecash/."
