#!/bin/bash
# =============================================================================
# feed-publish.sh — generate + sign + atomically publish a RUNTIME feed index
# =============================================================================
#
# This is the ONLY step that touches a published feed tree. It never builds:
# it takes the build job's artifact directory plus the build job's sha256
# manifest, and it will refuse to index anything whose bytes do not match that
# manifest. That refusal is what makes "the publish step only downloads and
# indexes" provable instead of asserted (docs/feed-index-publishing.md, gate 3).
#
# Guarantees, in publish order
#   1. every manifest entry exists and matches sha256  (no hidden rebuild)
#   2. package filenames are immutable + versioned     (no in-place re-cut)
#   3. packages are staged, then OLD VERSIONS ARE PRUNED to --keep N-1,
#      then the index is generated from what is actually in the tree
#   4. the apk index is SIGNED, and the signature is verified locally with the
#      public key(s) that are published next to it — an unsigned or mismatched
#      index can never leave this script (apk aborts such a repo with
#      "UNTRUSTED signature")
#   5. the index is swapped in by atomic rename (mv in the same directory)
#   6. the packages are copied to --publish-target BEFORE the index
#   7. the live index is re-fetched over the network and every package it lists
#      is fetched back and sha256-compared (scripts/feed-verify.sh)
#
# Layout (a full URL to the index FILE goes in the router's
# /etc/apk/repositories.d/<x>.list; opkg takes a directory URL):
#
#   <tree>/keys/<name>.pem
#   <tree>/<channel>/<line>/<arch>/packages.adb     (apk, mutable path)
#   <tree>/<channel>/<line>/<arch>/<pkg>-<ver>.apk  (immutable, versioned)
#   <tree>/<channel>/<line>/<arch>/Packages[.gz]    (opkg, only if a real
#                                                    artifact exists for the line)
#
# Requirements
#   * apk-tools v3 WITH the `mkndx` subcommand. The OpenWrt 25.12 *target*
#     rootfs apk does NOT have it; the SDK's host apk-tools does. Obtain one
#     with scripts/get-host-apk-tools.sh and pass it as --apk-bin (or
#     FEED_APK_BIN). The script refuses to run with an apk that has no mkndx.
#
# Usage: see --help
# =============================================================================
set -euo pipefail

PROG=${0##*/}
APK_BIN=${FEED_APK_BIN:-}
USIGN_BIN=${FEED_USIGN:-}
MAX_SECONDS=${FEED_MAX_PUBLISH_SECONDS:-300}

FORMAT=apk
CHANNEL=""
LINE=""
ARCH=""
TREE=""
ARTIFACTS=""
MANIFEST=""
SIGN_KEY=""
KEYS_DIR=""
DESCRIPTION=""
BASE_URL=""
CA_CERT=""
PUBLISH_TARGET=""
KEEP=2
DRY_RUN=0
UNSIGNED=0
IPKG_INDEX=""
RECORD=""

PHASE_NAMES=()
PHASE_TIMES=()
PHASE_START=0

usage() {
	cat <<'EOF'
feed-publish.sh — generate, sign and atomically publish a runtime feed index.

SYNOPSIS
  feed-publish.sh --artifacts DIR --manifest FILE --tree DIR \
                  --channel testing --line 25.12 --arch aarch64_cortex-a53 \
                  --sign-key DIR/tollgate-testing.sec --keys-dir DIR [options]

REQUIRED
  --artifacts DIR     directory holding the built packages (never written to)
  --manifest FILE     sha256 manifest from the BUILD job ("<sha256>  <file>");
                      produce it with scripts/feed-manifest.sh
  --tree DIR          durable feed tree root (the generated tree; commit it or
                      keep it on a second host)
  --channel NAME      prod | testing | ...
  --line VERSION      OpenWrt release line, e.g. 25.12
  --arch TUPPLE       ARCH_PACKAGES, e.g. aarch64_cortex-a53

INDEX
  --format apk|opkg   default apk
  --sign-key FILE     EC P-256 private key (PEM). REQUIRED for --format apk.
  --keys-dir DIR      directory containing ONLY public *.pem keys; they are
                      copied to <tree>/keys/ and used to verify the index
                      signature locally before it is published. REQUIRED for
                      --format apk.
  --description TEXT  index description (default: "TollGate <channel> <line>/<arch>")
  --apk-bin PATH      apk-tools 3 binary WITH mkndx (default $FEED_APK_BIN, else
                      `apk` from PATH). The target rootfs apk has no mkndx.
  --ipkg-index PATH   ipkg-make-index.sh from the matching OpenWrt SDK
                      (opkg only; default $FEED_IPKG_INDEX)
  --unsigned          build an UNSIGNED apk index. Test-only: it is the
                      negative case of the trust gate. Refuses unless
                      FEED_ALLOW_UNSIGNED=1 is set as well.
  --keep N            retained versions per package (default 2 => current + N-1
                      rollback). 0 disables pruning.

PUBLISH
  --publish-target D  rsync destination (local path, or user@host:/path).
                      Packages are copied first, then the index, atomically
                      (rsync --delay-updates).
  --base-url URL      public base URL of the tree; enables the fetch-back
                      assertion (scripts/feed-verify.sh)
  --ca-cert FILE      curl --cacert for the fetch-back (staging / self-signed)
  --record FILE       write a JSON record of this publish (index sha256, key
                      id, package sha256s, phase timings) — commit this
  --max-seconds N     fail if the whole run exceeds N seconds (default 300);
                      a hidden recompile shows up here
  --dry-run           validate everything, print the plan, change nothing
  -h|--help
EOF
}

log()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

phase() { # phase <name> — end the previous phase, start a new one
	local now
	now=$(date +%s.%N)
	if [ -n "${PHASE_CUR:-}" ]; then
		PHASE_TIMES+=("$(awk -v a="$PHASE_START" -v b="$now" 'BEGIN{printf "%.2f", b-a}')")
	fi
	PHASE_NAMES+=("$1")
	PHASE_CUR=$1
	PHASE_START=$now
}

phase_summary() {
	local i total=0
	printf '%-24s %10s\n' "phase" "elapsed"
	for i in "${!PHASE_NAMES[@]}"; do
		printf '%-24s %9ss\n' "${PHASE_NAMES[$i]}" "${PHASE_TIMES[$i]:-0}"
		total=$(awk -v t="$total" -v d="${PHASE_TIMES[$i]:-0}" 'BEGIN{printf "%.2f", t+d}')
	done
	printf '%-24s %9ss   (limit %ss)\n' "TOTAL" "$total" "$MAX_SECONDS"
	awk -v t="$total" -v m="$MAX_SECONDS" 'BEGIN{exit !(t<=m)}' \
		|| die "publish took ${total}s > ${MAX_SECONDS}s: that is long enough to be a hidden rebuild — the publish step must only download and index"
}

# ---------------------------------------------------------------- arguments --
while [ $# -gt 0 ]; do
	case "$1" in
		--artifacts)    ARTIFACTS=${2:?}; shift 2 ;;
		--manifest)     MANIFEST=${2:?}; shift 2 ;;
		--tree)         TREE=${2:?}; shift 2 ;;
		--channel)      CHANNEL=${2:?}; shift 2 ;;
		--line)         LINE=${2:?}; shift 2 ;;
		--arch)         ARCH=${2:?}; shift 2 ;;
		--format)       FORMAT=${2:?}; shift 2 ;;
		--sign-key)     SIGN_KEY=${2:?}; shift 2 ;;
		--keys-dir)     KEYS_DIR=${2:?}; shift 2 ;;
		--description)  DESCRIPTION=${2:?}; shift 2 ;;
		--apk-bin)      APK_BIN=${2:?}; shift 2 ;;
		--usign)        USIGN_BIN=${2:?}; shift 2 ;;
		--ipkg-index)   IPKG_INDEX=${2:?}; shift 2 ;;
		--keep)         KEEP=${2:?}; shift 2 ;;
		--publish-target) PUBLISH_TARGET=${2:?}; shift 2 ;;
		--base-url)     BASE_URL=${2:?}; shift 2 ;;
		--ca-cert)      CA_CERT=${2:?}; shift 2 ;;
		--record)       RECORD=${2:?}; shift 2 ;;
		--max-seconds)  MAX_SECONDS=${2:?}; shift 2 ;;
		--unsigned)     UNSIGNED=1; shift ;;
		--dry-run)      DRY_RUN=1; shift ;;
		-h|--help)      usage; exit 0 ;;
		*)              die "unknown argument: $1 (see --help)" ;;
	esac
done

[ -n "$ARTIFACTS" ] || die "--artifacts is required"
[ -n "$MANIFEST" ]  || die "--manifest is required"
[ -n "$TREE" ]      || die "--tree is required"
[ -n "$CHANNEL" ]   || die "--channel is required"
[ -n "$LINE" ]      || die "--line is required"
[ -n "$ARCH" ]      || die "--arch is required"
case "$FORMAT" in apk|opkg) ;; *) die "--format must be apk or opkg" ;; esac
case "$CHANNEL" in */*|.|..) die "--channel must be a single path element" ;; esac
case "$LINE" in */*|.|..)   die "--line must be a single path element" ;; esac
case "$ARCH" in */*|.|..)   die "--arch must be a single path element" ;; esac
[ -d "$ARTIFACTS" ] || die "artifact dir not found: $ARTIFACTS"
[ -f "$MANIFEST" ]  || die "manifest not found: $MANIFEST"

ARTIFACTS=$(cd "$ARTIFACTS" && pwd)
TREE_ABS=$(mkdir -p "$TREE" && cd "$TREE" && pwd)
MANIFEST=$(cd "$(dirname "$MANIFEST")" && pwd)/$(basename "$MANIFEST")

DEST="$TREE_ABS/$CHANNEL/$LINE/$ARCH"
[ -n "$DESCRIPTION" ] || DESCRIPTION="TollGate $CHANNEL feed $LINE/$ARCH"

# ------------------------------------------------------------- apk tooling ---
resolve_apk() {
	[ -n "$APK_BIN" ] || APK_BIN=$(command -v apk || true)
	[ -n "$APK_BIN" ] || die "no apk-tools binary: pass --apk-bin (scripts/get-host-apk-tools.sh can extract one)"
	[ -x "$APK_BIN" ] || die "apk binary is not executable: $APK_BIN"
	APK_BIN=$(cd "$(dirname "$APK_BIN")" && pwd)/$(basename "$APK_BIN")
	# NOTE: `apk mkndx --help` exits 1 in this build, so probe the TEXT, not the
	# exit status. The target rootfs apk answers with its generic command list.
	probe=$("$APK_BIN" mkndx --help 2>&1 || true)
	printf '%s' "$probe" | grep -q '^Usage: apk mkndx' \
		|| die "$APK_BIN has no 'mkndx' subcommand. The OpenWrt 25.12 target rootfs apk cannot build indexes; use the SDK host apk-tools (scripts/get-host-apk-tools.sh)."
	# A relative --keys-dir is silently ignored by apk-tools 3.0.5 (measured:
	# verification then reports UNTRUSTED). Always hand it absolute paths.
	"$APK_BIN" --version >/dev/null 2>&1 || die "apk binary does not run: $APK_BIN"
}

# -------------------------------------------------------------- manifest -----
# Lines: "<sha256>  <file>" (sha256sum output, '*' separator accepted).
read_manifest() {
	awk '{
		sum=$1; name=$2
		sub(/^\*/, "", name)
		if (sum ~ /^[0-9a-f]{64}$/ && name != "") print sum "\t" name
	}' "$MANIFEST"
}

MANIFEST_ROWS=$(read_manifest) || die "manifest is unreadable: $MANIFEST"
[ -n "$MANIFEST_ROWS" ] || die "manifest has no '<sha256>  <file>' rows: $MANIFEST"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

count=0
total_bytes=0
declare -a PKG_FILES=()

manifest_check() {
	local sum name file actual base
	while IFS=$'\t' read -r sum name; do
		[ -n "$name" ] || continue
		file="$ARTIFACTS/$name"
		[ -f "$file" ] || die "manifest lists '$name' but it is not in $ARTIFACTS"
		base=$(basename "$name")
		[ "$base" = "$name" ] || die "manifest entry must be a bare filename: $name"
		actual=$(sha256sum "$file" | cut -d' ' -f1)
		[ "$actual" = "$sum" ] \
			|| die "sha256 MISMATCH for $name: manifest=$sum artifact=$actual — the artifact was rebuilt or modified after the build job; publish what was built, do not re-cut it here"
		case "$FORMAT" in
			apk)
				[[ "$base" =~ ^[A-Za-z0-9][A-Za-z0-9+._-]*-[0-9][A-Za-z0-9+._~-]*\.apk$ ]] \
					|| die "package filename is not immutable-versioned: $base (expected <name>-<version>.apk)"
				;;
			opkg)
				[[ "$base" =~ ^[A-Za-z0-9][A-Za-z0-9+.-]*_[A-Za-z0-9._~+-]+_[A-Za-z0-9._-]+\.ipk$ ]] \
					|| die "package filename is not immutable-versioned: $base (expected <name>_<version>_<arch>.ipk)"
				;;
		esac
		PKG_FILES+=("$base")
		count=$((count + 1))
		total_bytes=$((total_bytes + $(stat -c %s "$file")))
		printf '%s\t%s\n' "$actual" "$base"
	done <<<"$MANIFEST_ROWS"
}

# ------------------------------------------------------------- re-cut guard --
# A file with the same name but different bytes is the failure mode the memo
# calls out: "a re-cut of the SAME version is invisible to apk upgrade".
recut_check() {
	local -a rows=("$@")
	local sum base existing
	for row in "${rows[@]}"; do
		sum=${row%%$'\t'*}; base=${row#*$'\t'}
		existing="$DEST/$base"
		[ -f "$existing" ] || continue
		if [ "$(sha256sum "$existing" | cut -d' ' -f1)" != "$sum" ]; then
			die "$base already exists in the tree with DIFFERENT bytes. Do not republish different bytes under an old version: bump PKG_RELEASE (e.g. -r2) so package managers actually see the change."
		fi
		warn "$base already published with identical bytes — re-publishing the same bytes (idempotent)"
	done
}

# ---------------------------------------------------------------- staging ----
stage_packages() {
	local row sum base src dst
	mkdir -p "$DEST"
	for row in "${MANIFEST_ROWS_ARR[@]}"; do
		sum=${row%%$'\t'*}; base=${row#*$'\t'}
		src="$ARTIFACTS/$base"; dst="$DEST/$base"
		[ -f "$dst" ] && continue
		if [ "$DRY_RUN" = 1 ]; then
			note "would copy $base ($(stat -c %s "$src") bytes)"
		else
			cp -f "$src" "$dst.tmp" && mv -f "$dst.tmp" "$dst"
			note "staged $base"
		fi
	done
}

# -------------------------------------------------------------- retention ----
# Keep --keep versions per package name (newest mtime wins). Never touch a file
# that this publish is about to index as new, and never touch anything while
# --dry-run is set.
prune_versions() {
	[ "$KEEP" -gt 0 ] || { note "retention disabled (--keep 0)"; return 0; }
	local ext
	case "$FORMAT" in apk) ext=apk ;; opkg) ext=ipk ;; esac
	local -A newest=()
	local f base pkg
	# collect distinct package names by stripping "-<version>.<ext>"
	while IFS= read -r f; do
		base=${f##*/}
		pkg=${base%-*-*.$ext}
		newest[$pkg]=1
	done < <(ls -1 "$DEST"/*."$ext" 2>/dev/null || true)
	local p
	for p in "${!newest[@]}"; do
		local -a all=()
		while IFS= read -r f; do all+=("$f"); done \
			< <(ls -1t "$DEST/$p"-*."$ext" 2>/dev/null || true)
		local i
		for ((i = KEEP; i < ${#all[@]}; i++)); do
			base=${all[$i]##*/}
			if [ "$DRY_RUN" = 1 ]; then
				note "would prune old version $base"
			else
				rm -f "${all[$i]}"
				note "pruned old version $base (kept $KEEP)"
			fi
		done
	done
}

# ---------------------------------------------------------------- indexing ---
generate_index() {
	case "$FORMAT" in
		apk) generate_apk_index ;;
		opkg) generate_opkg_index ;;
	esac
}

generate_apk_index() {
	local -a pkgs=()
	local f
	for f in "$DEST"/*.apk; do [ -f "$f" ] || continue; pkgs+=("${f##*/}"); done
	[ "${#pkgs[@]}" -gt 0 ] || die "no .apk files in $DEST — refusing to publish an empty index"
	# Deterministic order: the same inputs must produce the same index bytes.
	local sorted
	sorted=$(printf '%s\n' "${pkgs[@]}" | LC_ALL=C sort)

	local -a args=(mkndx --root "$DEST" --keys-dir "$KEYS_DIR_ABS" \
		--allow-untrusted --description "$DESCRIPTION" --output "$DEST/packages.adb.tmp")
	if [ "$UNSIGNED" = 1 ]; then
		[ "${FEED_ALLOW_UNSIGNED:-0}" = 1 ] \
			|| die "--unsigned produces a feed that every apk-based router REFUSES ('UNTRUSTED signature'). Set FEED_ALLOW_UNSIGNED=1 to confirm you want the negative case."
		warn "building an UNSIGNED index (test/negative case only)"
	else
		[ -n "$SIGN_KEY" ] || die "--sign-key is required for --format apk (an unsigned index breaks apk update for every tester)"
		[ -f "$SIGN_KEY" ] || die "sign key not found: $SIGN_KEY"
		SIGN_KEY_ABS=$(cd "$(dirname "$SIGN_KEY")" && pwd)/$(basename "$SIGN_KEY")
		args+=(--sign-key "$SIGN_KEY_ABS")
	fi
	if [ "$DRY_RUN" = 1 ]; then
		note "would run: apk mkndx --root $DEST --keys-dir $KEYS_DIR_ABS --allow-untrusted${SIGN_KEY_ABS:+ --sign-key <key>} --output packages.adb.tmp $(printf '%s ' $sorted)"
		return 0
	fi
	local line
	while IFS= read -r line; do args+=("$line"); done <<<"$sorted"
	(cd "$DEST" && "$APK_BIN" "${args[@]}") >&2
	[ -f "$DEST/packages.adb.tmp" ] || die "mkndx did not produce packages.adb"
	note "index built: packages.adb.tmp ($(stat -c %s "$DEST/packages.adb.tmp") bytes, ${#pkgs[@]} packages)"
}

generate_opkg_index() {
	[ -n "$IPKG_INDEX" ] || IPKG_INDEX=${FEED_IPKG_INDEX:-}
	[ -n "$IPKG_INDEX" ] || die "--ipkg-index is required for --format opkg (scripts/ipkg-make-index.sh from the matching OpenWrt SDK)"
	# The SDK's ipkg-make-index.sh is a *bash* script (it uses [[ ]]) whose shebang
	# is `#!/usr/bin/env bash`; run it through bash explicitly so the exec bit is
	# not required on a fetched copy.
	[ -f "$IPKG_INDEX" ] || die "ipkg index script not found: $IPKG_INDEX"
	local n
	n=$(ls -1 "$DEST"/*.ipk 2>/dev/null | wc -l)
	[ "$n" -gt 0 ] || die "no .ipk files in $DEST — refusing to publish an empty index"
	if [ "$DRY_RUN" = 1 ]; then
		note "would run: $IPKG_INDEX $DEST > Packages.manifest && filter && gzip -9nc"
		return 0
	fi
	# ipkg-make-index.sh hashes with "$MKHASH sha256 <file>". In the OpenWrt build
	# system MKHASH is tools/mkhash (a two-argument wrapper); plain `sha256sum`
	# does NOT work there (it would see two file arguments). Use mkhash when it
	# exists, otherwise an equivalent shim.
	local mkhash_cmd=${MKHASH:-}
	if [ -z "$mkhash_cmd" ]; then
		if command -v mkhash >/dev/null 2>&1; then
			mkhash_cmd=mkhash
		else
			cat > "$TMP/mkhash-shim" <<'SH'
#!/bin/sh
# mkhash-compatible shim: "mkhash <alg> <file>..." -> the bare digest.
# NOTE: OpenWrt's mkhash prints ONLY the hash; `sha256sum` prints "<hash>  <file>",
# and the second field contains a "/" which breaks the sed expression inside
# ipkg-make-index.sh. Strip it.
shift
exec sha256sum "$@" | cut -d' ' -f1
SH
			chmod +x "$TMP/mkhash-shim"
			mkhash_cmd="$TMP/mkhash-shim"
		fi
	fi
	if ! (cd "$DEST" && MKHASH="$mkhash_cmd" bash "$IPKG_INDEX" .) \
			> "$DEST/Packages.manifest.tmp" 2> "$TMP/ipkg.err"; then
		sed 's/^/  ipkg-make-index: /' "$TMP/ipkg.err" >&2
		die "ipkg-make-index.sh failed (see above)"
	fi
	[ -s "$DEST/Packages.manifest.tmp" ] || die "ipkg-make-index.sh produced no output"
	# Fields stock opkg's package listings do not want.
	grep -vE '^(Maintainer|LicenseFiles|Source|SourceName|Require|SourceDateEpoch)' \
		"$DEST/Packages.manifest.tmp" > "$DEST/Packages.tmp" || true
	[ -s "$DEST/Packages.tmp" ] || die "field filtering emptied Packages"
	# usign bug workaround, exactly as OpenWrt's package/Makefile does it: pad
	# the list with two newlines when (64+size) % 128 is 110 or 111.
	pad=$(( (64 + $(stat -c %s "$DEST/Packages.tmp")) % 128 ))
	if [ "$pad" -eq 110 ] || [ "$pad" -eq 111 ]; then
		printf '\n\n' >> "$DEST/Packages.tmp"
		note "applied the usign padding workaround (64+size mod 128 = $pad)"
	fi
	if [ "$UNSIGNED" = 1 ]; then
		warn "building an UNSIGNED opkg index. MEASURED: stock 24.10/23.05 RELEASE images put 'option check_signature' in /etc/opkg.conf, and opkg then aborts on it ('Signature file download failed'). Only use this for the negative test case."
	else
		[ -n "$SIGN_KEY" ] || die "--sign-key (a usign secret key) is required for --format opkg: an unsigned list makes 'opkg update' fail on stock 24.10/23.05 release images (see docs/feed-index-publishing.md). Use --unsigned only for the negative case."
		[ -f "$SIGN_KEY" ] || die "sign key not found: $SIGN_KEY"
		[ -n "$USIGN_BIN" ] || USIGN_BIN=$(command -v usign || true)
		[ -n "$USIGN_BIN" ] || die "usign not found: install it or pass --usign/ FEED_USIGN"
		SIGN_KEY_ABS=$(cd "$(dirname "$SIGN_KEY")" && pwd)/$(basename "$SIGN_KEY")
		mkdir -p "$TMP/opkg"
		cp -f "$DEST/Packages.tmp" "$TMP/opkg/Packages"
		"$USIGN_BIN" -S -m "$TMP/opkg/Packages" -s "$SIGN_KEY_ABS" >&2 \
			|| die "usign -S failed"
		[ -f "$TMP/opkg/Packages.sig" ] || die "usign produced no Packages.sig"
		mv -f "$TMP/opkg/Packages.sig" "$DEST/Packages.sig.tmp"
		# key id = the usign fingerprint of the published public key (this is
		# also the file name the router installs it under: /etc/opkg/keys/<fp>)
		SIG_ID=""
		for p in "$KEYS_DIR_ABS"/*.pub; do
			[ -f "$p" ] || continue
			SIG_ID=$("$USIGN_BIN" -F -p "$p" 2>/dev/null || true)
			[ -n "$SIG_ID" ] && break
		done
		note "opkg index signed with usign (Packages.sig, $(stat -c %s "$DEST/Packages.sig.tmp") bytes)"
	fi
	gzip -9nc "$DEST/Packages.tmp" > "$DEST/Packages.gz.tmp"
	note "opkg index built: Packages.tmp ($(stat -c %s "$DEST/Packages.tmp") bytes) + Packages.gz.tmp$( [ "$UNSIGNED" = 1 ] && echo ' (unsigned)' || echo ' + Packages.sig.tmp' )"
}

# --------------------------------------------------------- atomic swap -------
atomic_swap_index() {
	if [ "$DRY_RUN" = 1 ]; then note "would atomically rename the index into place"; return 0; fi
	case "$FORMAT" in
		apk)
			# One rename, same directory, same filesystem: a reader either sees
			# the old index or the new one, never a partial file.
			mv -f "$DEST/packages.adb.tmp" "$DEST/packages.adb"
			note "packages.adb swapped in by atomic rename"
			;;
		opkg)
			mv -f "$DEST/Packages.tmp" "$DEST/Packages"
			mv -f "$DEST/Packages.gz.tmp" "$DEST/Packages.gz"
			mv -f "$DEST/Packages.manifest.tmp" "$DEST/Packages.manifest"
			[ -f "$DEST/Packages.sig.tmp" ] && mv -f "$DEST/Packages.sig.tmp" "$DEST/Packages.sig"
			note "Packages / Packages.gz / Packages.manifest$( [ -f "$DEST/Packages.sig" ] && echo ' / Packages.sig' ) swapped in by atomic rename"
			;;
	esac
}

# --------------------------------------------------------- signature check ---
assert_signed() {
	if [ "$FORMAT" = opkg ]; then
		[ "$DRY_RUN" = 1 ] && return 0
		[ "$UNSIGNED" = 1 ] && { note "unsigned opkg index (negative case) — signature check skipped by design"; return 0; }
		[ -f "$DEST/Packages.sig" ] || die "no Packages.sig: opkg would refuse this list on a stock 24.10/23.05 image"
		for p in "$KEYS_DIR_ABS"/*.pub; do
			[ -f "$p" ] || continue
			"$USIGN_BIN" -V -m "$DEST/Packages" -p "$p" >/dev/null 2>&1 \
				|| die "Packages.sig does not verify with the published key $p"
		done
		note "Packages.sig verified with the published usign key (fingerprint ${SIG_ID:-unknown})"
		return 0
	fi
	[ "$DRY_RUN" = 1 ] && { note "would verify the index signature with $KEYS_DIR_ABS"; return 0; }
	if [ "$UNSIGNED" = 1 ]; then
		note "unsigned index (negative case) — signature check skipped by design"
		return 0
	fi
	# Two assertions: a signature block EXISTS, and it verifies against the very
	# public key(s) we publish. apk needs an ABSOLUTE --keys-dir (a relative one
	# is silently ignored, which is how UNTRUSTED slips through unnoticed).
	local dump
	dump=$("$APK_BIN" --root "$DEST" --keys-dir "$KEYS_DIR_ABS" adbdump "$DEST/packages.adb")
	printf '%s\n' "$dump" | grep -q '^# sig ' \
		|| die "the index has NO signature block — apk would refuse it (UNTRUSTED signature)"
	printf '%s\n' "$dump" | grep -q '^# sig .*: OK$' \
		|| die "index signature does not verify with the published key(s) in $KEYS_DIR_ABS: $(printf '%s\n' "$dump" | grep '^# sig ') — fixing this is mandatory; do NOT tell testers to use --allow-untrusted"
	SIG_ID=$(printf '%s\n' "$dump" | sed -n 's/^# sig v[0-9a-f]* h[0-9a-f]* \([0-9a-f]\{32\}\).*/\1/p' | head -1)
	note "signature verified with the published key(s): key id ${SIG_ID:-unknown}"
}

index_listing() { # -> "<name>-<version>.apk" per line, straight from the index
	if [ "$FORMAT" = apk ]; then
		"$APK_BIN" --root "$DEST" --keys-dir "$KEYS_DIR_ABS" adbdump "$DEST/packages.adb" 2>/dev/null \
			| awk '
				/^  - name: /  { name=$3 }
				/^    version: / { printf "%s-%s.apk\n", name, $2 }
			' | LC_ALL=C sort
	else
		zcat "$DEST/Packages.gz" | awk '/^Filename: /{print $2}' | LC_ALL=C sort
	fi
}

# ------------------------------------------------------------- arch check ----
# Failure mode the memo calls out and nothing else here notices: an
# Architecture mismatch (aarch64_cortex-a53 vs aarch64_generic) reaches the
# router as "package not found". The package builds, the index signs, the
# fetch-back assertion matches — the wrong arch only shows up when a tester
# installs. The index is what the router reads, so that is where we assert,
# against the arch the SDK reported (ARCH_PACKAGES).
assert_arch() {
	[ "$DRY_RUN" = 1 ] && { note "would assert the index Architecture matches --arch $ARCH"; return 0; }
	local declared="" bad="" a
	case "$FORMAT" in
		apk)
			# Check existence, then assign in a SEPARATE statement: inside
			# `local x=$(cmd)` a failing command does not trip `set -e`, so a
			# missing/again-unbuilt index would silently read as empty.
			[ -f "$DEST/packages.adb" ] || die "no packages.adb in $DEST — nothing to check the Architecture of"
			declared=$("$APK_BIN" --root "$DEST" --keys-dir "$KEYS_DIR_ABS" adbdump "$DEST/packages.adb" 2>/dev/null \
				| awk '/^    arch: /{print $2}' | LC_ALL=C sort -u)
			;;
		opkg)
			[ -f "$DEST/Packages.gz" ] || die "no Packages.gz in $DEST — nothing to check the Architecture of"
			declared=$(zcat "$DEST/Packages.gz" 2>/dev/null | sed -n 's/^Architecture: *//p' | LC_ALL=C sort -u)
			;;
	esac
	[ -n "$declared" ] || die "the index declares no Architecture at all (did the index build fail?)"
	for a in $declared; do
		case "$a" in
			"$ARCH"|all|noarch) ;;
			*) bad="$bad $a" ;;
		esac
	done
	[ -z "$bad" ] || die "the index declares Architecture '$bad' but this publish is --arch $ARCH. Use the arch the SDK reports (ARCH_PACKAGES); apk/opkg reject a mismatch as 'package not found' and nothing earlier in this pipeline would have caught it."
	note "index Architecture matches --arch $ARCH (declared: $(printf '%s' "$declared" | tr '\n' ' '))"
}

# ------------------------------------------------------------- publishing ----
publish_packages() {
	[ -n "$PUBLISH_TARGET" ] || { note "no --publish-target: tree only (local)"; return 0; }
	[ "$DRY_RUN" = 1 ] && { note "would rsync packages to $PUBLISH_TARGET"; return 0; }
	local ext; case "$FORMAT" in apk) ext=apk ;; opkg) ext=ipk ;; esac
	if [ "$FORMAT" = opkg ]; then
		# opkg pulls .ipk + its index from the same directory
		rsync -a --delay-updates --include='*/' --include="*.$ext" --include='sha256sums' --exclude='*' \
			"$TREE_ABS/" "$PUBLISH_TARGET/" >&2
	else
		rsync -a --delay-updates --include='*/' --include="*.$ext" --exclude='*' \
			"$TREE_ABS/" "$PUBLISH_TARGET/" >&2
	fi
	note "packages published to $PUBLISH_TARGET (before the index)"
}

publish_index() {
	[ -n "$PUBLISH_TARGET" ] || return 0
	[ "$DRY_RUN" = 1 ] && { note "would rsync the index to $PUBLISH_TARGET"; return 0; }
	local rel="$CHANNEL/$LINE/$ARCH"
	local -a files=()
	case "$FORMAT" in
		apk) files=("packages.adb") ;;
		opkg) files=("Packages" "Packages.gz" "Packages.manifest" "Packages.sig") ;;
	esac
	local f
	for f in "${files[@]}"; do
		[ -f "$DEST/$f" ] || continue
		# --delay-updates transfers to a temp name and renames at the end of the
		# transfer: the published index is never a half-written file.
		rsync -a --delay-updates "$DEST/$f" "$PUBLISH_TARGET/$rel/$f" >&2
	done
	note "index published to $PUBLISH_TARGET/$rel (atomically, after the packages)"
}

sha256sums_file() {
	[ "$FORMAT" = opkg ] || return 0
	[ "$DRY_RUN" = 1 ] && return 0
	(cd "$DEST" && sha256sum ./*.ipk Packages Packages.gz $( [ -f Packages.sig ] && echo Packages.sig ) > sha256sums)
	note "wrote sha256sums (opkg does not verify package payloads; see the memo)"
}

verify_live() {
	[ -n "$BASE_URL" ] || { note "no --base-url: fetch-back assertion skipped"; return 0; }
	local here; here=$(cd "$(dirname "$0")" && pwd)
	local -a args=(--base-url "$BASE_URL" --channel "$CHANNEL" --line "$LINE" \
		--arch "$ARCH" --format "$FORMAT" --manifest "$MANIFEST")
	[ -n "$CA_CERT" ] && args+=(--ca-cert "$CA_CERT")
	[ -n "${APK_BIN:-}" ] && args+=(--apk-bin "$APK_BIN")
	echo "--- fetch-back assertion (live) ---" >&2
	"$here/feed-verify.sh" "${args[@]}"
}

write_record() {
	[ -n "$RECORD" ] || return 0
	[ "$DRY_RUN" = 1 ] && return 0
	local idx_sha="-" idx_bytes=0
	case "$FORMAT" in
		apk) [ -f "$DEST/packages.adb" ] && { idx_sha=$(sha256sum "$DEST/packages.adb" | cut -d' ' -f1); idx_bytes=$(stat -c %s "$DEST/packages.adb"); } ;;
		opkg) [ -f "$DEST/Packages.gz" ] && { idx_sha=$(sha256sum "$DEST/Packages.gz" | cut -d' ' -f1); idx_bytes=$(stat -c %s "$DEST/Packages.gz"); } ;;
	esac
	{
		printf '{\n'
		printf '  "channel": "%s",\n  "line": "%s",\n  "arch": "%s",\n  "format": "%s",\n' "$CHANNEL" "$LINE" "$ARCH" "$FORMAT"
		printf '  "index": "%s",\n  "index_bytes": %s,\n  "index_sha256": "%s",\n' "$(basename "$DEST")/$([ "$FORMAT" = apk ] && echo packages.adb || echo Packages.gz)" "$idx_bytes" "$idx_sha"
		printf '  "signature": {"alg": "ecdsa-p256-sha512", "key_id": "%s", "signed": %s},\n' "${SIG_ID:-}" "$([ "$FORMAT" = apk ] && [ "$UNSIGNED" = 0 ] && echo true || echo false)"
		printf '  "published_at": "%s",\n' "$(date -u +%FT%TZ)"
		printf '  "packages": [\n'
		local first=1 row sum base
		for row in "${MANIFEST_ROWS_ARR[@]}"; do
			sum=${row%%$'\t'*}; base=${row#*$'\t'}
			[ "$first" = 1 ] || printf ',\n'
			first=0
			printf '    {"filename": "%s", "sha256": "%s", "bytes": %s}' "$base" "$sum" "$(stat -c %s "$DEST/$base")"
		done
		printf '\n  ]\n}\n'
	} > "$RECORD"
	note "record written: $RECORD"
}

# ================================================================== run =====
T0=$(date +%s.%N)
log "== feed-publish: $CHANNEL/$LINE/$ARCH ($FORMAT)"
log "   artifacts : $ARTIFACTS"
log "   tree      : $TREE_ABS"
log "   dest      : $DEST"

if [ "$FORMAT" = apk ]; then
	[ -n "$KEYS_DIR" ] || die "--keys-dir is required for --format apk (it holds the public key(s) the router will trust, and indexes are built and checked against it)"
	[ -d "$KEYS_DIR" ] || die "keys dir not found: $KEYS_DIR"
	KEYS_DIR_ABS=$(cd "$KEYS_DIR" && pwd)
	bad=$(find "$KEYS_DIR_ABS" -maxdepth 1 -type f ! -name '*.pem' -printf '%f\n' 2>/dev/null || true)
	[ -z "$bad" ] || die "keys dir contains non-.pem files ($(printf '%s ' $bad)) — it must hold ONLY public keys; private keys never go near a published tree"
	ls -1 "$KEYS_DIR_ABS"/*.pem >/dev/null 2>&1 || die "keys dir has no *.pem public key: $KEYS_DIR_ABS"
	resolve_apk
else
	# opkg path: the published key is a usign public key (keys/<name>.pub), and
	# stock 24.10/23.05 RELEASE images enable signature checking, so signing is
	# the default here too (--unsigned is the documented negative case).
	if [ "$UNSIGNED" = 1 ]; then
		KEYS_DIR_ABS=${KEYS_DIR_ABS:-}
	else
		[ -n "$KEYS_DIR" ] || die "--keys-dir is required for --format opkg (the usign public key the router installs via opkg-key)"
		[ -d "$KEYS_DIR" ] || die "keys dir not found: $KEYS_DIR"
		KEYS_DIR_ABS=$(cd "$KEYS_DIR" && pwd)
		bad=$(find "$KEYS_DIR_ABS" -maxdepth 1 -type f ! -name '*.pub' -printf '%f\n' 2>/dev/null || true)
		[ -z "$bad" ] || die "keys dir contains non-.pub files ($(printf '%s ' $bad)) — for opkg it must hold ONLY usign public keys"
		ls -1 "$KEYS_DIR_ABS"/*.pub >/dev/null 2>&1 || die "keys dir has no *.pub usign public key: $KEYS_DIR_ABS"
		[ -n "$USIGN_BIN" ] || USIGN_BIN=$(command -v usign || true)
		[ -n "$USIGN_BIN" ] || die "usign not found: install it or pass --usign / FEED_USIGN"
	fi
fi

phase manifest
note "manifest: $MANIFEST ($(grep -vc '^#' "$MANIFEST" || true) package row(s))"
manifest_check > "$TMP/manifest.rows"
mapfile -t MANIFEST_ROWS_ARR < "$TMP/manifest.rows"
note "verified $count artifact(s), $total_bytes bytes, 0 sha256 mismatches"
phase "recut-guard"
recut_check "${MANIFEST_ROWS_ARR[@]}"

phase "stage-packages"
stage_packages

phase "prune-old-versions"
prune_versions

phase "generate-index"
generate_index

phase "atomic-swap-index"
atomic_swap_index

phase "arch-check"
assert_arch

phase "signature-check"
assert_signed
if [ "$FORMAT" = opkg ]; then sha256sums_file; fi

phase "publish"
publish_packages
publish_index

phase "publish-keys"
if [ "$DRY_RUN" != 1 ] && [ -n "$KEYS_DIR_ABS" ]; then
	mkdir -p "$TREE_ABS/keys"
	# A published key file must never change under a router's feet: same name
	# with different material silently breaks trust for everyone who already
	# installed it. Rotate deliberately (new name, or feed-keygen --force plus
	# a documented re-install step), do not let a publish do it by accident.
	kf="" name="" dest=""
	case "$FORMAT" in apk) keyglob='*.pem' ;; opkg) keyglob='*.pub' ;; esac
	for kf in "$KEYS_DIR_ABS"/$keyglob; do
		[ -f "$kf" ] || continue
		name=$(basename "$kf"); dest="$TREE_ABS/keys/$name"
		if [ -f "$dest" ] && [ "$(sha256sum "$kf" | cut -d' ' -f1)" != "$(sha256sum "$dest" | cut -d' ' -f1)" ]; then
			die "keys/$name already exists in the tree with DIFFERENT key material. Overwriting it would silently break the trust chain for every router that installed the old key. Use a new key name (or a documented rotation)."
		fi
	done
	cp -f "$KEYS_DIR_ABS"/$keyglob "$TREE_ABS/keys/"
	note "public key(s) copied to $TREE_ABS/keys/"
	if [ -n "$PUBLISH_TARGET" ]; then
		rsync -a --delay-updates --include='*/' --include="$keyglob" --exclude='*' "$TREE_ABS/keys/" "$PUBLISH_TARGET/keys/" >&2
		note "public key(s) published to $PUBLISH_TARGET/keys/"
	fi
fi

phase "verify-live"
verify_live

write_record

phase "done"
printf '\n'
log "---------------------------------------------------------------"
log "publish summary — $CHANNEL/$LINE/$ARCH ($FORMAT)"
log "---------------------------------------------------------------"
if [ "$DRY_RUN" != 1 ]; then
	note "index : $( [ "$FORMAT" = apk ] && echo "$DEST/packages.adb" || echo "$DEST/Packages.gz" )"
	note "sha256: $( [ "$FORMAT" = apk ] && sha256sum "$DEST/packages.adb" | cut -d' ' -f1 || sha256sum "$DEST/Packages.gz" | cut -d' ' -f1 )"
	note "listed: $(index_listing | tr '\n' ' ')"
fi
phase_summary
T1=$(date +%s.%N)
log ""
log "NO-REBUILD PROOF: $count artifact(s) sha256-verified against the build"
log "manifest (0 mismatches); commands invoked: sha256sum, cp, mv, rm, $( [ "$FORMAT" = apk ] && echo "apk mkndx, apk adbdump" || echo "ipkg-make-index.sh, gzip" ), curl/rsync. No compiler or build system was invoked."
awk -v a="$T0" -v b="$T1" 'BEGIN{printf "total wall clock: %.2f s\n", b-a}'
log "OK"
