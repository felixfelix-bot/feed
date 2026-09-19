#!/bin/bash
# =============================================================================
# tests/opkg-index-test.sh — the opkg side, measured on a real 24.10 rootfs
# =============================================================================
#
# The memo's opkg section says "stock opkg does NOT verify signatures ... so
# ship UNSIGNED". That was checked against the OpenWrt SOURCE tree, where
# package/system/opkg/files/opkg.conf indeed has no check_signature. RELEASE
# images are different: package/system/opkg/Makefile does
#
#     ifneq ($(CONFIG_SIGNATURE_CHECK),)
#     echo "option check_signature" >> $(1)/etc/opkg.conf
#     endif
#
# and official releases are built with it — so the shipped /etc/opkg.conf HAS
# the (bare) option, and a bare option ENABLES the check. This test proves that
# on a real OpenWrt 24.10.8 rootfs and shows the two working configurations.
#
# Cases (all with a locally served tree produced by scripts/feed-publish.sh):
#   A. no check_signature         + unsigned list  -> opkg update 0, install works
#   B. bare `option check_signature` + unsigned list -> opkg update FAILS
#      ("Signature file download failed") — this is a stock 24.10 image
#   C. bare `option check_signature` + SIGNED list (Packages.sig + key installed
#      via opkg-key) -> opkg update 0, install and run work
#
# Requirements: docker, python3, usign, and scripts/ipkg-make-index.sh from an
# OpenWrt SDK (pass --ipkg-index). The fixture .ipk is built here with plain
# tar/gzip, so no SDK is needed for the package itself.
#
# Usage: tests/opkg-index-test.sh --ipkg-index <path> [--usign PATH]
#                                [--image IMG] [--keep]
# =============================================================================
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
IPKG_INDEX=""
USIGN_BIN=${FEED_USIGN:-}
IMAGE=${FEED_TEST_OPKG_IMAGE:-openwrt/rootfs:x86_64-24.10.8}
KEEP=0

while [ $# -gt 0 ]; do
	case "$1" in
		--ipkg-index) IPKG_INDEX=${2:?}; shift 2 ;;
		--usign)      USIGN_BIN=${2:?}; shift 2 ;;
		--image)      IMAGE=${2:?}; shift 2 ;;
		--keep)       KEEP=1; shift ;;
		-h|--help) sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 1 ;;
	esac
done

[ -n "$IPKG_INDEX" ] || { echo "SKIP: --ipkg-index <scripts/ipkg-make-index.sh> is required" >&2; exit 2; }
[ -f "$IPKG_INDEX" ] || { echo "FAIL: no such ipkg index script: $IPKG_INDEX" >&2; exit 1; }
command -v docker >/dev/null || { echo "SKIP: docker not available" >&2; exit 2; }
command -v python3 >/dev/null || { echo "SKIP: python3 not available" >&2; exit 2; }
if [ -z "$USIGN_BIN" ]; then
	for cand in "$REPO/.feed-tools/apk/bin/usign" "$HOME/.feed-tools/apk/bin/usign"; do
		[ -x "$cand" ] && USIGN_BIN=$cand && break
	done
fi
[ -n "$USIGN_BIN" ] || { echo "SKIP: usign not found (scripts/get-host-apk-tools.sh extracts one; or --usign)" >&2; exit 2; }
export FEED_USIGN="$USIGN_BIN"

WORK=$(mktemp -d)
cleanup() {
	[ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null || true
	[ "$KEEP" = 1 ] && echo "work dir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/pkgs/CONTROL" "$WORK/pkgs/usr/bin" "$WORK/srv"

# ---------------------------------------------------------------- fixture ----
# An .ipk is a gzipped tar of debian-binary + control.tar.gz + data.tar.gz.
build_ipk() {
	local name=tollgate-opkgfixture
	local ver=$1 arch=x86_64
	local d="$WORK/ipkbuild"
	local ipkname="${name}_${ver}_${arch}.ipk"
	rm -rf "$d"; mkdir -p "$d/control" "$d/data/usr/bin"
	printf '#!/bin/sh\necho tollgate-opkgfixture %s\n' "${ver%%-*}" > "$d/data/usr/bin/tollgate-opkgfixture"
	chmod 755 "$d/data/usr/bin/tollgate-opkgfixture"
	cat > "$d/control/control" <<EOF
Package: tollgate-opkgfixture
Version: $ver
Depends: libc
Source: https://github.com/OpenTollGate/tollgate-module-basic-go
SourceName: tollgate-opkgfixture
License: MIT
LicenseFiles: LICENSE
Maintainer: TollGate <tollgate@tollgate.me>
Section: net
SourceDateEpoch: 1757720000
Architecture: $arch
Installed-Size: 40
Description: TollGate opkg index fixture (built by tests/opkg-index-test.sh)
EOF
	( cd "$d/control" && tar czf ../control.tar.gz . )
	( cd "$d/data" && tar czf ../data.tar.gz . )
	printf '2.0\n' > "$d/debian-binary"
	( cd "$d" && tar czf "$WORK/pkgs/$ipkname" ./debian-binary ./control.tar.gz ./data.tar.gz )
	echo "$WORK/pkgs/$ipkname"
}

IPK=$(build_ipk "0.6.0~alpha1-r1")
echo "== fixture package: $IPK"
bash "$REPO/scripts/feed-manifest.sh" "$WORK/pkgs" --format opkg --out "$WORK/build.sha256" >/dev/null
bash "$REPO/scripts/feed-keygen.sh" --out "$WORK/keys" --name tollgate-testing --type usign >/dev/null
FP=$("$USIGN_BIN" -F -p "$WORK/keys/pub/tollgate-testing.pub")
echo "== usign key fingerprint: $FP"

publish() { # <channel> <extra...>
	local channel=$1; shift
	bash "$REPO/scripts/feed-publish.sh" --format opkg \
		--artifacts "$WORK/pkgs" --manifest "$WORK/build.sha256" --tree "$WORK/srv" \
		--channel "$channel" --line 24.10 --arch x86_64 \
		--ipkg-index "$IPKG_INDEX" --usign "$USIGN_BIN" \
		--keys-dir "$WORK/keys/pub" --sign-key "$WORK/keys/tollgate-testing.sec" "$@"
}
echo "== publishing a SIGNED list"
publish testing >/dev/null
echo "== publishing an UNSIGNED list (negative case)"
FEED_ALLOW_UNSIGNED=1 publish _negative-unsigned --unsigned >/dev/null

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/srv" >/dev/null 2>&1 &
SRV_PID=$!
for _ in $(seq 1 40); do
	curl -fsS -o /dev/null "http://127.0.0.1:$PORT/testing/24.10/x86_64/Packages.gz" && break
	sleep 0.25
done
echo "== served at http://127.0.0.1:$PORT"

run_case() { # <name> <options: none|bare> <channel> <install-key: yes|no> <expect 0|nonzero>
	local name=$1 opts=$2 channel=$3 usekey=$4 expect=$5
	local script out upd
	script=$(cat <<EOF
mkdir -p /tmp/o /var/opkg-lists /var/lock /etc/opkg/keys
printf 'src/gz tg http://127.0.0.1:$PORT/$channel/24.10/x86_64\ndest root /\ndest ram /tmp\nlists_dir ext /var/opkg-lists\n' > /tmp/o/opkg.conf
$( [ "$opts" = bare ] && echo 'printf "option check_signature\n" >> /tmp/o/opkg.conf' || echo ':' )
$( [ "$usekey" = yes ] && echo "wget -qO /tmp/k.pub http://127.0.0.1:$PORT/keys/tollgate-testing.pub && opkg-key add /tmp/k.pub && echo \"key_exit=\$?\"" || echo 'echo "key_exit=skipped"' )
opkg -f /tmp/o/opkg.conf update
echo "update_exit=\$?"
opkg -f /tmp/o/opkg.conf list tollgate-opkgfixture
opkg -f /tmp/o/opkg.conf install tollgate-opkgfixture
echo "install_exit=\$?"
tollgate-opkgfixture
echo "run_exit=\$?"
opkg -f /tmp/o/opkg.conf remove tollgate-opkgfixture
echo "remove_exit=\$?"
EOF
)
	out=$(docker run --rm --network host "$IMAGE" sh -c "$script" 2>&1) || true
	upd=$(printf '%s\n' "$out" | sed -n 's/^update_exit=//p' | tail -1)
	printf '\n--- case %s (check_signature=%s, repo=%s, key=%s, expect=%s)\n' "$name" "$opts" "$channel" "$usekey" "$expect"
	printf '%s\n' "$out" | sed 's/^/    /'
	if [ "$expect" = 0 ]; then
		[ "${upd:-1}" = 0 ] || { echo "    RESULT: FAIL (expected opkg update to succeed)"; return 1; }
		printf '%s\n' "$out" | grep -q '^install_exit=0' || { echo "    RESULT: FAIL (install failed)"; return 1; }
		printf '%s\n' "$out" | grep -q '^run_exit=0' || { echo "    RESULT: FAIL (installed binary did not run)"; return 1; }
		printf '%s\n' "$out" | grep -q '^remove_exit=0' || { echo "    RESULT: FAIL (remove failed)"; return 1; }
		echo "    RESULT: PASS (update/install/run/remove all 0)"
		return 0
	fi
	[ "${upd:-0}" != 0 ] || { echo "    RESULT: FAIL (expected opkg update to fail, it exited 0)"; return 1; }
	printf '%s\n' "$out" | grep -q 'Signature file download failed' \
		|| { echo "    RESULT: FAIL (update failed but not on the missing signature)"; return 1; }
	echo "    RESULT: PASS (opkg update refused the unsigned list)"
	return 0
}

fails=0
run_case "A no check_signature, unsigned list"  none _negative-unsigned no  0        || fails=$((fails + 1))
run_case "B bare check_signature, unsigned list" bare _negative-unsigned no  nonzero  || fails=$((fails + 1))
run_case "C bare check_signature, SIGNED list"   bare testing            yes 0        || fails=$((fails + 1))

echo
echo "================================================================"
if [ "$fails" -gt 0 ]; then
	echo "opkg gate: FAIL — $fails case(s)"
	exit 1
fi
echo "opkg gate: PASS — 3/3 (unsigned lists are only usable where check_signature is off)"
echo "image under test: $IMAGE ($(docker run --rm "$IMAGE" sh -c '. /etc/openwrt_release; echo "$DISTRIB_DESCRIPTION"; opkg --version' 2>/dev/null | tr '\n' ' '))"
echo "shipped /etc/opkg.conf check_signature line: $(docker run --rm "$IMAGE" grep -c check_signature /etc/opkg.conf 2>/dev/null)"
