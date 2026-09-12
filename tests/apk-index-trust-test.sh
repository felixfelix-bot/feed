#!/bin/bash
# =============================================================================
# tests/apk-index-trust-test.sh — GATE 1: signing is mandatory, and it works
# =============================================================================
#
# Runs the REAL OpenWrt apk-tools (from an OpenWrt 25.12.5 rootfs image) against
# a feed tree produced by scripts/feed-publish.sh, over HTTP, and asserts:
#
#   A. UNSIGNED index + key installed   -> `apk update` FAILS, "UNTRUSTED signature"
#   B. SIGNED index   + key installed   -> `apk update` SUCCEEDS and lists the package
#   C. SIGNED index   + key NOT installed -> FAILS (the one documented curl is
#                                            not optional)
#   D. SIGNED index   + WRONG key installed -> FAILS
#   E. SIGNED index   + key installed   -> `apk add` installs the package and the
#                                          installed file runs
#
# The package used is a tiny fixture built with `apk mkpkg` (arch x86_64, so the
# x86_64 rootfs can actually install it). It proves the INDEX TRUST mechanics on
# real apk-tools; installing the real tollgate-wrt package on router hardware is
# a different gate (FEED-SERVE-PROVE / RC-ACCEPTANCE).
#
# Requirements: docker, python3, and an apk-tools 3 host binary that has
# mkndx+mkpkg+adbdump — scripts/get-host-apk-tools.sh extracts one from the SDK.
#
# Usage:
#   tests/apk-index-trust-test.sh [--apk-bin PATH] [--image IMG] [--keep]
# =============================================================================
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
APK_BIN=${FEED_APK_BIN:-}
IMAGE=${FEED_TEST_IMAGE:-openwrt/rootfs:x86_64-25.12.5}
KEEP=0

while [ $# -gt 0 ]; do
	case "$1" in
		--apk-bin) APK_BIN=${2:?}; shift 2 ;;
		--image)   IMAGE=${2:?}; shift 2 ;;
		--keep)    KEEP=1; shift ;;
		-h|--help) sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 1 ;;
	esac
done

if [ -z "$APK_BIN" ]; then
	for cand in "$REPO/.feed-tools/apk/bin/apk" /home/c03rad0r/feed-index/apk/bin/apk; do
		[ -x "$cand" ] && APK_BIN=$cand && break
	done
fi
[ -n "$APK_BIN" ] || { echo "SKIP: no apk-tools host binary (run scripts/get-host-apk-tools.sh and pass --apk-bin)" >&2; exit 2; }
command -v docker >/dev/null || { echo "SKIP: docker not available" >&2; exit 2; }
command -v python3 >/dev/null || { echo "SKIP: python3 not available" >&2; exit 2; }

# The index builder must be the BUILD-HOST apk-tools; the 25.12 target rootfs
# apk has no mkndx at all (measured).
# NOTE: `apk mkndx --help` exits 1, so a pipeline would trip `pipefail` even on
# a match — capture the text first.
apk_probe=$("$APK_BIN" mkndx --help 2>&1 || true)
printf '%s' "$apk_probe" | grep -q '^Usage: apk mkndx' \
	|| { echo "FAIL: $APK_BIN has no mkndx subcommand" >&2; exit 1; }

WORK=$(mktemp -d)
cleanup() {
	[ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null || true
	[ "$KEEP" = 1 ] && echo "work dir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/pkgs/files/usr/bin" "$WORK/srv"
printf '#!/bin/sh\necho tollgate-fixture 0.6.0\n' > "$WORK/pkgs/files/usr/bin/tollgate-fixture"
chmod 755 "$WORK/pkgs/files/usr/bin/tollgate-fixture"
(cd "$WORK/pkgs" && "$APK_BIN" mkpkg \
	--info name:tollgate-fixture --info version:0.6.0_alpha1-r1 --info arch:x86_64 \
	--info description:"TollGate index trust fixture" --info license:MIT \
	--files "$WORK/pkgs/files" --output "$WORK/pkgs/tollgate-fixture-0.6.0_alpha1-r1.apk") >/dev/null 2>&1

bash "$REPO/scripts/feed-manifest.sh" "$WORK/pkgs" --out "$WORK/build.sha256" >/dev/null
bash "$REPO/scripts/feed-keygen.sh" --out "$WORK/keys" --name tollgate-testing >/dev/null
bash "$REPO/scripts/feed-keygen.sh" --out "$WORK/wrongkeys" --name tollgate-wrong >/dev/null

publish() { # <channel> <extra args...>
	local channel=$1; shift
	bash "$REPO/scripts/feed-publish.sh" \
		--artifacts "$WORK/pkgs" --manifest "$WORK/build.sha256" --tree "$WORK/srv/mine" \
		--channel "$channel" --line 25.12 --arch x86_64 \
		--keys-dir "$WORK/keys/pub" --sign-key "$WORK/keys/tollgate-testing.sec" \
		--apk-bin "$APK_BIN" "$@"
}
echo "== publishing the signed channel"
publish testing >/dev/null
echo "== publishing the unsigned (negative) channel"
FEED_ALLOW_UNSIGNED=1 publish _negative-unsigned --unsigned >/dev/null
# A second tree signed by a DIFFERENT key, so the wrong-key case installs
# genuinely different key material (filename alone proves nothing).
echo "== publishing a second tree with a different signing key"
bash "$REPO/scripts/feed-publish.sh" \
	--artifacts "$WORK/pkgs" --manifest "$WORK/build.sha256" --tree "$WORK/srv/wrong" \
	--channel testing --line 25.12 --arch x86_64 \
	--keys-dir "$WORK/wrongkeys/pub" --sign-key "$WORK/wrongkeys/tollgate-wrong.sec" \
	--apk-bin "$APK_BIN" >/dev/null

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/srv" >/dev/null 2>&1 &
SRV_PID=$!
for _ in $(seq 1 40); do
	curl -fsS -o /dev/null "http://127.0.0.1:$PORT/mine/testing/25.12/x86_64/packages.adb" && break
	sleep 0.25
done
curl -fsS -o /dev/null "http://127.0.0.1:$PORT/mine/testing/25.12/x86_64/packages.adb" \
	|| { echo "FAIL: local feed server did not come up on port $PORT" >&2; exit 1; }
echo "== feed tree served at http://127.0.0.1:$PORT"

run_case() { # <name> <expected 0|nonzero> <key: ours|none|wrong> <repo url path>
	local name=$1 expect=$2 keymode=$3 repopath=$4
	local setup
	case "$keymode" in
		ours)  setup="wget -qO /etc/apk/keys/tollgate-testing.pem http://127.0.0.1:$PORT/mine/keys/tollgate-testing.pem" ;;
		wrong) setup="wget -qO /etc/apk/keys/tollgate-wrong.pem http://127.0.0.1:$PORT/wrong/keys/tollgate-wrong.pem" ;;
		*)     setup=":" ;;
	esac
	local script
	script=$(cat <<EOF
mkdir -p /etc/apk/keys
$setup
printf '%s\n' 'http://127.0.0.1:$PORT/$repopath' > /tmp/repos.list
apk --repositories-file /tmp/repos.list update
echo "update_exit=\$?"
apk --repositories-file /tmp/repos.list search -v tollgate-fixture
echo "search_exit=\$?"
EOF
)
	local out upd
	out=$(docker run --rm --network host "$IMAGE" sh -c "$script" 2>&1) || true
	upd=$(printf '%s\n' "$out" | sed -n 's/^update_exit=//p' | tail -1)
	printf '\n--- case %s (key=%s repo=%s, expect=%s)\n' "$name" "$keymode" "$repopath" "$expect"
	printf '%s\n' "$out" | sed 's/^/    /'
	if [ "$expect" = 0 ]; then
		[ "${upd:-1}" = 0 ] || { echo "    RESULT: FAIL (expected apk update to succeed)"; return 1; }
		printf '%s\n' "$out" | grep -q 'tollgate-fixture' \
			|| { echo "    RESULT: FAIL (index did not list the package)"; return 1; }
		echo "    RESULT: PASS (apk update exit 0, package listed)"
		return 0
	fi
	if [ "${upd:-0}" = 0 ]; then
		echo "    RESULT: FAIL (expected apk update to FAIL, it exited 0)"
		return 1
	fi
	printf '%s\n' "$out" | grep -q 'UNTRUSTED signature' \
		|| { echo "    RESULT: FAIL (update failed but not with UNTRUSTED signature)"; return 1; }
	echo "    RESULT: PASS (apk update failed with UNTRUSTED signature)"
	return 0
}

install_case() {
	local script out
	script=$(cat <<EOF
mkdir -p /etc/apk/keys
wget -qO /etc/apk/keys/tollgate-testing.pem http://127.0.0.1:$PORT/mine/keys/tollgate-testing.pem
printf '%s\n' 'http://127.0.0.1:$PORT/mine/testing/25.12/x86_64/packages.adb' > /tmp/repos.list
apk --repositories-file /tmp/repos.list update
apk --repositories-file /tmp/repos.list add tollgate-fixture
echo "add_exit=\$?"
tollgate-fixture
echo "run_exit=\$?"
EOF
)
	out=$(docker run --rm --network host "$IMAGE" sh -c "$script" 2>&1) || true
	printf '\n--- case E (signed, key installed, apk add + run)\n'
	printf '%s\n' "$out" | sed 's/^/    /'
	printf '%s\n' "$out" | grep -q '^add_exit=0' || { echo "    RESULT: FAIL (apk add failed)"; return 1; }
	printf '%s\n' "$out" | grep -q '^run_exit=0' || { echo "    RESULT: FAIL (installed file did not run)"; return 1; }
	echo "    RESULT: PASS (installed from a signed index and the binary runs)"
	return 0
}

fails=0
run_case "A unsigned index, key installed"  nonzero none  mine/_negative-unsigned/25.12/x86_64/packages.adb || fails=$((fails + 1))
run_case "B signed index, key installed"    0        ours  mine/testing/25.12/x86_64/packages.adb            || fails=$((fails + 1))
run_case "C signed index, NO key installed" nonzero none  mine/testing/25.12/x86_64/packages.adb            || fails=$((fails + 1))
run_case "D signed index, WRONG key"        nonzero wrong mine/testing/25.12/x86_64/packages.adb            || fails=$((fails + 1))
install_case                                                                    || fails=$((fails + 1))

echo
echo "================================================================"
if [ "$fails" -gt 0 ]; then
	echo "GATE 1 (apk index trust): FAIL — $fails case(s)"
	exit 1
fi
echo "GATE 1 (apk index trust): PASS — 5/5"
echo "image under test: $IMAGE ($(docker run --rm "$IMAGE" sh -c '. /etc/openwrt_release; echo "$DISTRIB_DESCRIPTION"; apk --version' 2>/dev/null | tr '\n' ' '))"
echo "apk host tool   : $APK_BIN ($("$APK_BIN" --version))"
exit 0
