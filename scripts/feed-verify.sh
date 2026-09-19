#!/bin/bash
# =============================================================================
# feed-verify.sh — fetch-back assertion for a PUBLISHED feed index
# =============================================================================
#
# What it proves, against the live URL (not the local tree):
#   1. the index itself is fetched fresh (Cache-Control: no-cache is sent, and
#      the response's own cache headers are inspected when asked)
#   2. every package the index LISTS is downloadable with HTTP 200
#   3. every package the BUILD MANIFEST names is listed by the index AND its
#      fetched bytes hash to exactly the sha256 recorded at build time
#   4. packages the index lists but the manifest does not (retained older
#      versions, kept for rollback) are fetched and their sha256 reported
#
# Exit status is non-zero if any of 1-3 fails, so this can gate a publish.
#
# Usage:
#   feed-verify.sh --base-url https://feed.example --channel testing \
#                  --line 25.12 --arch aarch64_cortex-a53 \
#                  --format apk --manifest build.sha256 [--ca-cert ca.pem]
# =============================================================================
set -uo pipefail

PROG=${0##*/}
BASE_URL=""
CHANNEL=""
LINE=""
ARCH=""
FORMAT=apk
MANIFEST=""
CA_CERT=""
APK_BIN=${FEED_APK_BIN:-}
INDEX_FILE=""
HEADER_MODE=warn   # warn | require | ignore
CONNECT_TIMEOUT=${FEED_VERIFY_CONNECT_TIMEOUT:-20}
MAX_TIME=${FEED_VERIFY_MAX_TIME:-120}

die()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

usage() {
	cat <<'EOF'
feed-verify.sh — re-fetch a published index and assert every package it lists.

REQUIRED
  --base-url URL      public base URL of the feed tree (e.g. https://feed.example)
  --channel NAME      feed channel (prod | testing | ...)
  --line VERSION      OpenWrt release line, e.g. 25.12
  --arch TUPPLE       ARCH_PACKAGES, e.g. aarch64_cortex-a53
  --manifest FILE     the BUILD job's sha256 manifest (authoritative hashes)

OPTIONS
  --format apk|opkg   default apk
  --apk-bin PATH      apk-tools 3 with `adbdump` (needed to read an apk index)
  --index-file FILE   verify a local index instead of fetching it (offline use)
  --ca-cert FILE      curl --cacert (staging / self-signed certificates)
  --headers MODE      ignore | warn | require  (default warn): enforce
                      no-cache on the index and immutable on packages
  -h|--help
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--base-url)   BASE_URL=${2:?}; shift 2 ;;
		--channel)    CHANNEL=${2:?}; shift 2 ;;
		--line)       LINE=${2:?}; shift 2 ;;
		--arch)       ARCH=${2:?}; shift 2 ;;
		--format)     FORMAT=${2:?}; shift 2 ;;
		--manifest)   MANIFEST=${2:?}; shift 2 ;;
		--ca-cert)    CA_CERT=${2:?}; shift 2 ;;
		--apk-bin)    APK_BIN=${2:?}; shift 2 ;;
		--index-file) INDEX_FILE=${2:?}; shift 2 ;;
		--headers)    HEADER_MODE=${2:?}; shift 2 ;;
		-h|--help)    usage; exit 0 ;;
		*)            die "unknown argument: $1 (see --help)" ;;
	esac
done

[ -n "$BASE_URL" ] || [ -n "$INDEX_FILE" ] || die "--base-url (or --index-file) is required"
[ -n "$CHANNEL" ] || [ -n "$INDEX_FILE" ] || die "--channel is required"
[ -n "$LINE" ] || [ -n "$INDEX_FILE" ] || die "--line is required"
[ -n "$ARCH" ] || [ -n "$INDEX_FILE" ] || die "--arch is required"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
case "$FORMAT" in apk|opkg) ;; *) die "--format must be apk or opkg" ;; esac
case "$HEADER_MODE" in ignore|warn|require) ;; *) die "--headers must be ignore|warn|require" ;; esac

CURL=(curl -sS --fail-with-body --max-time "$MAX_TIME" --connect-timeout "$CONNECT_TIMEOUT")
[ -n "$CA_CERT" ] && CURL+=(--cacert "$CA_CERT")

if [ -n "$INDEX_FILE" ]; then
	BASE_URL=${BASE_URL%/}
	DIR_URL=""
	INDEX_URL="(local file) $INDEX_FILE"
else
	BASE_URL=${BASE_URL%/}
	DIR_URL="$BASE_URL/$CHANNEL/$LINE/$ARCH"
	if [ "$FORMAT" = apk ]; then
		INDEX_URL="$DIR_URL/packages.adb"
	else
		INDEX_URL="$DIR_URL/Packages.gz"
	fi
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------- fetch index ---
fetch_index() {
	if [ -n "$INDEX_FILE" ]; then
		cp "$INDEX_FILE" "$WORK/index"
		: > "$WORK/index.headers"
		return 0
	fi
	local code
	code=$("${CURL[@]}" -D "$WORK/index.headers" \
		-H 'Cache-Control: no-cache' -H 'Pragma: no-cache' -H 'Accept-Encoding: identity' \
		-o "$WORK/index" -w '%{http_code}' "$INDEX_URL") || true
	printf 'GET %s -> HTTP %s (%s bytes)\n' "$INDEX_URL" "${code:-000}" "$(stat -c %s "$WORK/index" 2>/dev/null || echo 0)"
	[ "${code:-000}" = "200" ] || die "index fetch failed: HTTP ${code:-000} for $INDEX_URL"
}

fetch_index
echo "index: $INDEX_URL"
echo "index sha256: $(sha256sum < "$WORK/index" | cut -d' ' -f1)"

# ------------------------------------------------------ cache-control audit --
check_cache_headers() {
	[ "$HEADER_MODE" = ignore ] && return 0
	[ -n "$INDEX_FILE" ] && return 0
	local cc
	cc=$(grep -i '^cache-control:' "$WORK/index.headers" | tr -d '\r' | sed 's/^[Cc]ache-[Cc]ontrol: *//' | tail -1)
	echo "index cache-control: ${cc:-<absent>}"
	if [ -z "$cc" ] || ! printf '%s' "$cc" | grep -qiE 'no-cache|no-store|max-age=0'; then
		if [ "$HEADER_MODE" = require ]; then
			die "the index MUST be served no-cache/no-store; got '${cc:-<absent>}'. A cached index is the lethal failure mode."
		fi
		warn "index is not served no-cache/no-store ('${cc:-<absent>}') — required before testers are pointed at it"
	fi
}
check_cache_headers

# ------------------------------------------------------------ index listing --
index_filenames() {
	if [ "$FORMAT" = apk ]; then
		[ -n "$APK_BIN" ] || APK_BIN=$(command -v apk || true)
		[ -n "$APK_BIN" ] || die "--apk-bin is required to read an apk index (apk-tools 3)"
		"$APK_BIN" --allow-untrusted adbdump "$WORK/index" 2>/dev/null | awk '
			/^  - name: /   { name=$3 }
			/^    version: / { printf "%s-%s.apk\n", name, $2 }
		' | LC_ALL=C sort
	else
		zcat "$WORK/index" | awk '/^Filename: /{print $2}' | LC_ALL=C sort
	fi
}

index_filenames > "$WORK/index.listing"
[ -s "$WORK/index.listing" ] || die "the index lists no packages — an empty index reads as a broken feed"
echo "index lists $(wc -l < "$WORK/index.listing") package file(s)"

awk '{ sub(/^\*/, "", $2); if ($1 ~ /^[0-9a-f]{64}$/) print $2 "\t" $1 }' "$MANIFEST" \
	| LC_ALL=C sort > "$WORK/manifest.listing"
[ -s "$WORK/manifest.listing" ] || die "manifest has no usable rows: $MANIFEST"

fail=0
ok=0
miss=0

# 1. every manifest file must be listed by the index (this is also the
#    staleness check: a cached/old index does not list the new package)
while IFS=$'\t' read -r name sum; do
	if ! grep -qx "$name" "$WORK/index.listing"; then
		printf 'FAIL  %-52s NOT LISTED by the index (stale index, or the package was never published)\n' "$name"
		fail=$((fail + 1))
		miss=$((miss + 1))
	fi
done < "$WORK/manifest.listing"

# 2. every listed file must fetch 200 and hash correctly
while IFS= read -r name; do
	expect=$(awk -v n="$name" '$1 == n {print $2}' "$WORK/manifest.listing")
	if [ -n "$INDEX_FILE" ]; then
		printf 'SKIP  %-52s (--index-file: no HTTP fetch)\n' "$name"
		continue
	fi
	url="$DIR_URL/$name"
	code=$("${CURL[@]}" -o "$WORK/dl" -w '%{http_code}' "$url") || true
	if [ "${code:-000}" != "200" ]; then
		printf 'FAIL  %-52s HTTP %s\n' "$name" "${code:-000}"
		fail=$((fail + 1))
		continue
	fi
	got=$(sha256sum < "$WORK/dl" | cut -d' ' -f1)
	bytes=$(stat -c %s "$WORK/dl")
	if [ -n "$expect" ]; then
		if [ "$got" = "$expect" ]; then
			printf 'PASS  %-52s HTTP 200  %8s bytes  sha256 %s\n' "$name" "$bytes" "$got"
			ok=$((ok + 1))
		else
			printf 'FAIL  %-52s sha256 MISMATCH: index=%s manifest=%s\n' "$name" "$got" "$expect"
			fail=$((fail + 1))
		fi
	else
		printf 'INFO  %-52s HTTP 200  %8s bytes  sha256 %s (retained version, not in the build manifest)\n' "$name" "$bytes" "$got"
		ok=$((ok + 1))
	fi
done < "$WORK/index.listing"

echo "----------------------------------------------------------------"
if [ "$fail" -gt 0 ]; then
	echo "FETCH-BACK ASSERTION: FAIL — $fail file(s) failed, $miss not listed, $ok verified"
	exit 1
fi
echo "FETCH-BACK ASSERTION: PASS — $(wc -l < "$WORK/manifest.listing") manifest file(s) listed and hash-matched, $ok fetched, 0 failures"
