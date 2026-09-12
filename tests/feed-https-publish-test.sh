#!/bin/bash
# =============================================================================
# tests/feed-https-publish-test.sh — GATE 2 + GATE 3 over a real HTTPS server
# =============================================================================
#
# Gate 2 (fetch-back assertion) and Gate 3 (no-rebuild proof) can only be
# proven against a URL, not against a local directory: a cached index, a broken
# cache header or a package that 404s are invisible until something fetches the
# tree the way a router does.
#
# This test publishes a real artifact set, serves the resulting tree over HTTPS
# with the PRODUCTION cache-header rules (tests/feed-https-server.py — the same
# rules as deploy/caddy-feed.Caddyfile.example), and then:
#
#   1. publish      — packages first, index last, signed, atomic rename, with
#                     phase timings and a JSON record
#   2. fetch-back   — feed-verify.sh --headers require: the live index must be
#                     no-cache, every Filename it lists must return 200 and hash
#                     to the sha256 recorded at build time
#   3. negative     — corrupt one served package: the fetch-back assertion MUST
#                     exit non-zero (a tampered package cannot pass silently)
#   4. restore      — re-fetch and assert the tree verifies again
#   5. no-rebuild   — every artifact sha256 is identical before and after the
#                     publish, and the publish log states no compiler ran
#
# Requirements: apk-tools 3 host binary with mkndx/adbdump (see
# scripts/get-host-apk-tools.sh), openssl, rsync, curl, python3, and a real
# built package to publish.
#
# Usage:
#   tests/feed-https-publish-test.sh [--artifacts DIR --arch TUPPLE]
#                                    [--apk-bin PATH] [--port N]
#                                    [--workdir DIR] [--keep]
#
#   --artifacts DIR   a real build output to publish (recommended: it is the
#                     artifact set a router would actually install)
#   --arch TUPPLE     ARCH_PACKAGES; required with --artifacts, and asserted
#                     against the index's own Architecture field
#   --workdir DIR     keep the work tree here (default: a temp dir)
#   --keep            do not delete the work tree, and leave the server up
#   (no --artifacts)  publish a tiny `apk mkpkg` fixture instead, so the gate
#                     runs in CI with no SDK build (arch defaults to x86_64)
# =============================================================================
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
ARTIFACTS=""
APK_BIN=${FEED_APK_BIN:-}
PORT=18443
ARCH=""
FIXTURE=0
KEEP=0
WORKDIR=""

while [ $# -gt 0 ]; do
	case "$1" in
		--artifacts) ARTIFACTS=${2:?}; shift 2 ;;
		--apk-bin)   APK_BIN=${2:?}; shift 2 ;;
		--arch)      ARCH=${2:?}; shift 2 ;;
		--port)      PORT=${2:?}; shift 2 ;;
		--workdir)   WORKDIR=${2:?}; shift 2 ;;
		--keep)      KEEP=1; shift ;;
		-h|--help)   sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)           echo "unknown argument: $1" >&2; exit 1 ;;
	esac
done

if [ -z "$ARTIFACTS" ]; then
	# No built packages to hand: publish a tiny fixture package instead (built
	# with `apk mkpkg`, exactly like the trust test's). The HTTPS gate is about
	# the publish/serve/fetch-back mechanics, not about the real payload, so a
	# fixture keeps it runnable in CI with no SDK build.
	FIXTURE=1
	: "${ARCH:=x86_64}"
else
	[ -d "$ARTIFACTS" ] || { echo "FAIL: no such directory: $ARTIFACTS" >&2; exit 1; }
	[ -n "$ARCH" ] || { echo "FAIL: --arch is required with --artifacts (it must equal the packages' Architecture field)" >&2; exit 1; }
fi
if [ -z "$APK_BIN" ]; then
	APK_BIN=$("$REPO/scripts/get-host-apk-tools.sh" --out "$PWD/.feed-tools/apk" >/dev/null 2>&1 && echo "$PWD/.feed-tools/apk/bin/apk") || true
fi
[ -x "$APK_BIN" ] || { echo "FAIL: --apk-bin (apk-tools 3 with mkndx) is required" >&2; exit 1; }

PASS=0
FAIL=0
ok()   { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

WORK=${WORKDIR:-$(mktemp -d)}
mkdir -p "$WORK"/{artifacts,keys,tree,serve,out}
if [ "$FIXTURE" = 1 ]; then
	mkdir -p "$WORK/fixture/files/usr/bin"
	printf '#!/bin/sh\necho tollgate-fixture 0.6.0\n' > "$WORK/fixture/files/usr/bin/tollgate-fixture"
	chmod 755 "$WORK/fixture/files/usr/bin/tollgate-fixture"
	(cd "$WORK/fixture" && "$APK_BIN" mkpkg \
		--info name:tollgate-fixture --info version:0.6.0_alpha1-r1 --info arch:"$ARCH" \
		--info description:"TollGate HTTPS publish fixture" --info license:MIT \
		--files "$WORK/fixture/files" \
		--output "$WORK/fixture/tollgate-fixture-0.6.0_alpha1-r1.apk") >/dev/null 2>&1
	ARTIFACTS="$WORK/fixture"
	echo "== fixture package: $WORK/fixture/tollgate-fixture-0.6.0_alpha1-r1.apk ($(stat -c %s "$WORK/fixture/tollgate-fixture-0.6.0_alpha1-r1.apk") bytes)"
fi
# artifacts are copied so the "did the publish modify the build output?" check
# compares against an untouched copy
cp -a "$ARTIFACTS"/. "$WORK/artifacts/"
ART="$WORK/artifacts"
LOG="$WORK/out"

sha_of() { (cd "$1" && find . -type f \( -name '*.apk' -o -name '*.ipk' \) -print0 \
	| sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1); }
BEFORE=$(sha_of "$ART")

echo "== work dir: $WORK"
echo "== apk-tools: $("$APK_BIN" --version)"

# ---------------------------------------------------------------- keypair ---
"$REPO/scripts/feed-keygen.sh" --out "$WORK/keys" --name tollgate-testing >"$LOG/keygen.txt" 2>&1
# feed-keygen.sh writes the private key to <out>/<name>.sec and the public key
# to <out>/pub/<name>.pem; pub/ is exactly the "public keys only" dir that
# feed-publish.sh insists on for --keys-dir
echo "== keypair: public-key sha256 $(sha256sum "$WORK/keys/pub/tollgate-testing.pem" | cut -c1-16)"

# ------------------------------------------------------------ build manifest --
"$REPO/scripts/feed-manifest.sh" "$ART" --out "$WORK/build.sha256" >"$LOG/manifest.txt" 2>&1
echo "== build manifest (the BUILD job's authoritative hashes):"
sed 's/^/   /' "$WORK/build.sha256"

# --------------------------------------------------------------- https serve --
"$REPO/tests/feed-https-server.py" --root "$WORK/serve" --port "$PORT" \
	--certdir "$WORK/tls" >"$LOG/server.log" 2>&1 &
SERVER_PID=$!
trap '[ "$KEEP" = 1 ] || { kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$WORK"; }; true' EXIT
for _ in $(seq 1 50); do
	curl -sk --max-time 2 "https://localhost:$PORT/" -o /dev/null && break
	sleep 0.1
done
CA="$WORK/tls/ca.pem"
[ -f "$CA" ] || { echo "FAIL: the HTTPS server did not produce a CA" >&2; exit 1; }
echo "== https server: https://localhost:$PORT (CA $CA)"

# ------------------------------------------------------------------ publish --
echo
echo "--- publish (packages first, then the index) ---"
set +e
"$REPO/scripts/feed-publish.sh" \
	--artifacts "$ART" --manifest "$WORK/build.sha256" \
	--tree "$WORK/tree" --channel testing --line 25.12 --arch "$ARCH" \
	--sign-key "$WORK/keys/tollgate-testing.sec" --keys-dir "$WORK/keys/pub" \
	--apk-bin "$APK_BIN" \
	--publish-target "$WORK/serve" \
	--base-url "https://localhost:$PORT" --ca-cert "$CA" \
	--record "$WORK/out/publish-record.json" 2>&1 | tee "$LOG/publish.txt"
pub_exit=${PIPESTATUS[0]}
set -e
echo "publish exit: $pub_exit"
if [ "$pub_exit" = "0" ]; then ok "publish exited 0"; else bad "publish exited $pub_exit"; fi

# The index is what the router reads: if its Architecture does not match the
# arch we published under, installs fail with "package not found" while every
# other check here still passes.
ARCH_DECLARED=$("$APK_BIN" --allow-untrusted adbdump "$WORK/tree/testing/25.12/$ARCH/packages.adb" 2>/dev/null \
	| awk '/^    arch: /{print $2}' | LC_ALL=C sort -u | tr '\n' ' ')
echo "index declares arch: ${ARCH_DECLARED:-<none>} (publishing as --arch $ARCH)"
if [ "$(printf '%s' "$ARCH_DECLARED" | tr -d ' ')" = "$ARCH" ]; then
	ok "the live index's Architecture matches --arch"
else
	bad "index Architecture '${ARCH_DECLARED:-<none>}' does not match --arch $ARCH"
fi

# ------------------------------------------------------- 2. explicit fetch-back --
echo
echo "--- fetch-back assertion (--headers require) ---"
set +e
"$REPO/scripts/feed-verify.sh" --base-url "https://localhost:$PORT" \
	--channel testing --line 25.12 --arch "$ARCH" --format apk \
	--manifest "$WORK/build.sha256" --apk-bin "$APK_BIN" \
	--ca-cert "$CA" --headers require 2>&1 | tee "$LOG/verify.txt"
ver_exit=${PIPESTATUS[0]}
set -e
echo "verify exit: $ver_exit"
if [ "$ver_exit" = "0" ]; then ok "fetch-back assertion passed on a live HTTPS index"; else bad "fetch-back assertion failed"; fi

# ------------------------------------------------------------- 3. negative ----
echo
echo "--- negative: corrupt one served package, the assertion MUST fail ---"
VICTIM=$(cd "$WORK/serve" && find . -name '*.apk' | head -1)
if [ -z "$VICTIM" ]; then
	bad "no .apk was published, cannot run the negative case"
else
	cp -a "$WORK/serve/$VICTIM" "$WORK/out/victim.orig"
	# one flipped byte in the middle of the package: same size, same name
	python3 - "$WORK/serve/$VICTIM" <<'PY'
import sys
p = sys.argv[1]
b = bytearray(open(p, 'rb').read())
b[len(b) // 2] ^= 0xFF
open(p, 'wb').write(b)
PY
	echo "corrupted: $VICTIM ($(stat -c %s "$WORK/serve/$VICTIM") bytes, one byte flipped)"
	set +e
	"$REPO/scripts/feed-verify.sh" --base-url "https://localhost:$PORT" \
		--channel testing --line 25.12 --arch "$ARCH" --format apk \
		--manifest "$WORK/build.sha256" --apk-bin "$APK_BIN" \
		--ca-cert "$CA" --headers require 2>&1 | tee "$LOG/verify-corrupt.txt"
	corrupt_exit=${PIPESTATUS[0]}
	set -e
	echo "verify exit with a corrupted package: $corrupt_exit"
	if [ "$corrupt_exit" != "0" ]; then ok "corrupted package is refused (exit $corrupt_exit)"; else bad "a corrupted package PASSED the fetch-back assertion"; fi

	cp -a "$WORK/out/victim.orig" "$WORK/serve/$VICTIM"
	echo "--- restored, re-verifying ---"
	set +e
	"$REPO/scripts/feed-verify.sh" --base-url "https://localhost:$PORT" \
		--channel testing --line 25.12 --arch "$ARCH" --format apk \
		--manifest "$WORK/build.sha256" --apk-bin "$APK_BIN" \
		--ca-cert "$CA" --headers require >"$LOG/verify-restored.txt" 2>&1
	restore_exit=$?
	set -e
	tail -3 "$LOG/verify-restored.txt" | sed 's/^/   /'
	if [ "$restore_exit" = "0" ]; then ok "restored tree verifies again"; else bad "restored tree did not verify"; fi
fi

# ------------------------------------------------------------- 4. no-rebuild --
echo
echo "--- no-rebuild proof ---"
AFTER=$(sha_of "$ART")
echo "artifacts sha256-of-sha256s before publish: $BEFORE"
echo "artifacts sha256-of-sha256s after  publish: $AFTER"
if [ "$BEFORE" = "$AFTER" ]; then ok "the publish step did not touch a single artifact"; else bad "artifact bytes changed during publish"; fi
if grep -q 'No compiler or build system was invoked' "$LOG/publish.txt"; then
	ok "publish log states no compiler/build system was invoked"
else
	bad "publish log does not state that no compiler ran"
fi
echo "--- phase timings ---"
sed -n '/^phase /,/TOTAL/p' "$LOG/publish.txt" | sed 's/^/   /'
echo "--- cache headers actually served (curl, live) ---"
PKGNAME=$(ls "$WORK/serve/testing/25.12/$ARCH" | grep '\.apk$' | head -1)
for p in "testing/25.12/$ARCH/packages.adb" "testing/25.12/$ARCH/$PKGNAME" "keys/tollgate-testing.pem"; do
	printf '   HEAD /%s\n' "$p"
	curl -sS -k --cacert "$CA" -o /dev/null -D - --max-time 10 -H 'Cache-Control: no-cache' \
		"https://localhost:$PORT/$p" | grep -iE '^(HTTP/|cache-control|pragma|content-length)' | sed 's/^/     /'
done
echo "--- server-side request log (cache policy per path) ---"
grep 'cache-control' "$LOG/server.log" | grep -v 'GET / ->' | sort -u | sed 's/^/   /' | head -10

echo
echo "================================================================"
if [ "$FAIL" -gt 0 ]; then
	echo "feed-https-publish test: FAIL — $PASS passed, $FAIL failed"
	echo "work dir kept for inspection: $WORK"
	KEEP=1
	exit 1
fi
echo "feed-https-publish test: PASS — $PASS/$((PASS + FAIL)) checks"
echo "apk host tool: $APK_BIN ($("$APK_BIN" --version))"
[ "$KEEP" = 1 ] || rm -rf "$WORK"
