#!/bin/bash
# =============================================================================
# feed-keygen.sh — create the EC P-256 keypair used to sign an apk feed index
# =============================================================================
#
# apk-tools REFUSES an unsigned index ("UNTRUSTED signature"), so every apk
# feed channel needs its own key. Channels are separated by PATH + INDEX + KEY
# (not by a git branch): a prod router must never see a testing key.
#
# Usage:
#   feed-keygen.sh --out DIR --name tollgate-testing [--force]
#
# Writes:
#   DIR/<name>.sec      EC P-256 private key, chmod 600, directory chmod 700.
#                       NEVER commit, never upload. Keep it in the CI secret
#                       store / your password manager; a leaked key signs
#                       packages for every router.
#   DIR/pub/<name>.pem  the matching public key, in its OWN directory so that
#                       the private key can never be handed to a tool that
#                       expects a public key directory (feed-publish.sh refuses
#                       a --keys-dir that holds anything but *.pem). This is the
#                       file published at <tree>/keys/<name>.pem and installed
#                       on routers with one curl.
#
# After generating, print the router-side install line:
#
#   curl -fsSL https://feed.example/keys/<name>.pem \
#     -o /etc/apk/keys/<name>.pem
#
# and the repository line (apk takes a full URL to the index FILE):
#
#   echo "https://feed.example/<channel>/<line>/<arch>/packages.adb" \
#     >> /etc/apk/repositories.d/<name>.list
# =============================================================================
set -euo pipefail
umask 077

OUT=""
NAME=""
FORCE=0

while [ $# -gt 0 ]; do
	case "$1" in
		--out)  OUT=${2:?}; shift 2 ;;
		--name) NAME=${2:?}; shift 2 ;;
		--force) FORCE=1; shift ;;
		-h|--help) sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 1 ;;
	esac
done

[ -n "$OUT" ] || { echo "FAIL: --out DIR is required" >&2; exit 1; }
[ -n "$NAME" ] || { echo "FAIL: --name is required (e.g. tollgate-testing)" >&2; exit 1; }
case "$NAME" in */*|*..*|"") echo "FAIL: --name must be a plain file name" >&2; exit 1 ;; esac

mkdir -p "$OUT/pub"
chmod 700 "$OUT"
OUT=$(cd "$OUT" && pwd)
SEC="$OUT/$NAME.sec"
PEM="$OUT/pub/$NAME.pem"

if [ -e "$SEC" ] && [ "$FORCE" != 1 ]; then
	echo "FAIL: $SEC exists — refusing to overwrite a signing key. Pass --force only if you intend to ROTATE it (routers would then need the new .pem)." >&2
	exit 1
fi

openssl ecparam -name prime256v1 -genkey -noout -out "$SEC"
chmod 600 "$SEC"
openssl ec -in "$SEC" -pubout -out "$PEM" 2>/dev/null
chmod 644 "$PEM"

# Sanity: the public key must parse as a public key, and the private one must
# be able to produce it again (i.e. they really are a pair).
openssl pkey -pubin -in "$PEM" -noout >/dev/null 2>&1 || { echo "FAIL: generated public key does not parse" >&2; exit 1; }
derived=$(openssl ec -in "$SEC" -pubout 2>/dev/null | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1)
published=$(openssl pkey -pubin -in "$PEM" -outform DER | sha256sum | cut -d' ' -f1)
[ "$derived" = "$published" ] || { echo "FAIL: keypair mismatch" >&2; exit 1; }

echo "private key : $SEC   (chmod 600 — NEVER commit, never publish, never pass as --keys-dir)"
echo "public key  : $PEM   (publish as <tree>/keys/$NAME.pem)"
echo "runtime flags: --sign-key $SEC --keys-dir $OUT/pub"
echo "public key sha256 (DER SPKI): $published"
echo
echo "key id reported by apk for this key (from a signed index):"
echo "  apk --root DIR --keys-dir DIR adbdump packages.adb | grep '^# sig '"
echo
echo "router-side install (one documented curl):"
echo "  curl -fsSL <BASE_URL>/keys/$NAME.pem -o /etc/apk/keys/$NAME.pem"
