#!/bin/bash
# =============================================================================
# tests/feed-publish-test.sh — the publish pipeline's refusal rules
# =============================================================================
#
# Everything the publish step must REFUSE, plus retention and dry-run, exercised
# end to end with the real apk-tools index builder and tiny fixture packages made
# with `apk mkpkg` (no docker, no network).
#
#   1. a manifest hash that disagrees with the artifact      -> refuse
#   2. a manifest entry that is not in --artifacts           -> refuse
#   3. a package filename with no version in it              -> refuse
#   4. same filename, DIFFERENT bytes already published      -> refuse (bump -rN)
#   5. a non-.pem file in the public keys dir                -> refuse
#   6. --unsigned without FEED_ALLOW_UNSIGNED=1              -> refuse
#   7. republishing a key with different material            -> refuse
#   8. --keep 2 retention                                    -> oldest pruned,
#                                                              index lists the rest
#   9. --dry-run                                             -> changes nothing
#
# Usage: tests/feed-publish-test.sh [--apk-bin PATH] [--keep]
# =============================================================================
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
APK_BIN=${FEED_APK_BIN:-}
KEEP=0

while [ $# -gt 0 ]; do
	case "$1" in
		--apk-bin) APK_BIN=${2:?}; shift 2 ;;
		--keep)    KEEP=1; shift ;;
		-h|--help) sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 1 ;;
	esac
done

if [ -z "$APK_BIN" ]; then
	for cand in "$REPO/.feed-tools/apk/bin/apk" "$HOME/.feed-tools/apk/bin/apk"; do
		[ -x "$cand" ] && APK_BIN=$cand && break
	done
fi
[ -n "$APK_BIN" ] || { echo "SKIP: no apk-tools host binary (scripts/get-host-apk-tools.sh; or --apk-bin)" >&2; exit 2; }
probe=$("$APK_BIN" mkndx --help 2>&1 || true)
printf '%s' "$probe" | grep -q '^Usage: apk mkndx' || { echo "FAIL: $APK_BIN has no mkndx" >&2; exit 1; }

WORK=$(mktemp -d)
cleanup() { [ "$KEEP" = 1 ] && echo "work dir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

pass=0; fail=0
check() { # <desc> <expect 0|nonzero> <file with output> [grep pattern]
	local desc=$1 expect=$2 out=$3 pat=${4:-}
	if [ -n "$pat" ] && ! grep -q -- "$pat" "$out"; then
		printf 'FAIL  %s (output did not contain: %s)\n' "$desc" "$pat"; fail=$((fail + 1)); return 1
	fi
	printf 'PASS  %s\n' "$desc"; pass=$((pass + 1)); return 0
}

mkpkg() { # <dir> <version> <pkgfile-must-be-versioned>
	local dir=$1 ver=$2 name=${3:-tollgate-fixture}
	mkdir -p "$dir/files/usr/bin"
	printf '#!/bin/sh\necho %s %s\n' "$name" "$ver" > "$dir/files/usr/bin/$name"
	chmod 755 "$dir/files/usr/bin/$name"
	(cd "$dir" && "$APK_BIN" mkpkg --info name:"$name" --info version:"$ver" \
		--info arch:x86_64 --info description:"publish-test fixture" --info license:MIT \
		--files "$dir/files" --output "$dir/${name}-${ver}.apk") >/dev/null 2>&1
}

# fixture sets: three versions of one package
A="$WORK/a"; mkpkg "$A" "0.6.0_alpha1-r1"
B="$WORK/b"; mkpkg "$B" "0.6.0_alpha1-r2"
C="$WORK/c"; mkpkg "$C" "0.6.0_alpha1-r3"
bash "$REPO/scripts/feed-manifest.sh" "$A" --out "$WORK/a.sha256" >/dev/null
bash "$REPO/scripts/feed-manifest.sh" "$B" --out "$WORK/b.sha256" >/dev/null
bash "$REPO/scripts/feed-manifest.sh" "$C" --out "$WORK/c.sha256" >/dev/null
bash "$REPO/scripts/feed-keygen.sh" --out "$WORK/keys" --name tollgate-testing >/dev/null
bash "$REPO/scripts/feed-keygen.sh" --out "$WORK/other" --name tollgate-testing >/dev/null   # same NAME, different material

publish() { # <outfile> <tree> <artifacts> <manifest> [extra...]
	local out=$1 tree=$2 arts=$3 man=$4; shift 4
	bash "$REPO/scripts/feed-publish.sh" --artifacts "$arts" --manifest "$man" --tree "$tree" \
		--channel testing --line 25.12 --arch x86_64 \
		--keys-dir "$WORK/keys/pub" --sign-key "$WORK/keys/tollgate-testing.sec" \
		--apk-bin "$APK_BIN" "$@" > "$out" 2>&1
	printf '%s' "$?"
}

T="$WORK/tree"
rc=$(publish "$WORK/o1" "$T" "$A" "$WORK/a.sha256"); check "baseline publish succeeds" 0 "$WORK/o1" "OK" && [ "$rc" = 0 ]

# 1. manifest/artifact hash disagreement
cp "$WORK/a.sha256" "$WORK/bad.sha256"
sed -i 's/^[0-9a-f]\{64\}/'"$(printf '0%.0s' $(seq 1 64))"'/' "$WORK/bad.sha256"
rc=$(publish "$WORK/o2" "$WORK/t2" "$A" "$WORK/bad.sha256")
[ "$rc" != 0 ] && check "manifest/artifact hash mismatch is refused" nonzero "$WORK/o2" "sha256 MISMATCH" \
	|| { echo "FAIL  hash mismatch NOT refused"; fail=$((fail+1)); }

# 2. manifest entry missing from --artifacts
sed -i 's|tollgate-fixture-0.6.0_alpha1-r1.apk|tollgate-fixture-0.6.0_alpha1-r9.apk|' "$WORK/bad.sha256"
rc=$(publish "$WORK/o3" "$WORK/t3" "$A" "$WORK/bad.sha256")
[ "$rc" != 0 ] && check "manifest entry missing from the artifact dir is refused" nonzero "$WORK/o3" "not in" \
	|| { echo "FAIL  missing artifact NOT refused"; fail=$((fail+1)); }

# 3. unversioned filename — refused by feed-manifest.sh (the build job's gate)
#    and independently by feed-publish.sh if a hand-written manifest slips past
D="$WORK/d"; mkpkg "$D" "0.6.0_alpha1-r1"; mv "$D"/tollgate-fixture-*.apk "$D/tollgate-fixture.apk"
bash "$REPO/scripts/feed-manifest.sh" "$D" --out "$WORK/d.sha256" > "$WORK/o3a" 2>&1
[ "$?" != 0 ] && check "feed-manifest.sh refuses an unversioned filename" nonzero "$WORK/o3a" "not immutable-versioned" \
	|| { echo "FAIL  feed-manifest.sh accepted an unversioned filename"; fail=$((fail+1)); }
{ sha256sum "$D/tollgate-fixture.apk" | sed 's/  .*\//  /'; } > "$WORK/d2.sha256"
rc=$(publish "$WORK/o4" "$WORK/t4" "$D" "$WORK/d2.sha256")
[ "$rc" != 0 ] && check "feed-publish.sh refuses an unversioned filename" nonzero "$WORK/o4" "not immutable-versioned" \
	|| { echo "FAIL  unversioned name NOT refused by publish"; fail=$((fail+1)); }

# 4. re-cut: same filename, different bytes
E="$WORK/e"; mkpkg "$E" "0.6.0_alpha1-r1"
printf 'extra\n' >> "$E/files/usr/bin/tollgate-fixture"
rm -f "$E"/*.apk
(cd "$E" && "$APK_BIN" mkpkg --info name:tollgate-fixture --info version:0.6.0_alpha1-r1 \
	--info arch:x86_64 --info description:"re-cut" --info license:MIT \
	--files "$E/files" --output "$E/tollgate-fixture-0.6.0_alpha1-r1.apk") >/dev/null 2>&1
bash "$REPO/scripts/feed-manifest.sh" "$E" --out "$WORK/e.sha256" >/dev/null
rc=$(publish "$WORK/o5" "$T" "$E" "$WORK/e.sha256")
[ "$rc" != 0 ] && check "re-cut of a published version is refused (-rN advice)" nonzero "$WORK/o5" "PKG_RELEASE" \
	|| { echo "FAIL  re-cut NOT refused"; fail=$((fail+1)); }

# 5. non-.pem file in the keys dir
mkdir -p "$WORK/badkeys"; cp "$WORK/keys/pub/tollgate-testing.pem" "$WORK/badkeys/"; touch "$WORK/badkeys/tollgate.sec"
bash "$REPO/scripts/feed-publish.sh" --artifacts "$B" --manifest "$WORK/b.sha256" --tree "$WORK/t5" \
	--channel testing --line 25.12 --arch x86_64 --keys-dir "$WORK/badkeys" \
	--sign-key "$WORK/keys/tollgate-testing.sec" --apk-bin "$APK_BIN" > "$WORK/o6" 2>&1
[ "$?" != 0 ] && check "a private key in the keys dir is refused" nonzero "$WORK/o6" "ONLY public keys" \
	|| { echo "FAIL  bad keys dir NOT refused"; fail=$((fail+1)); }

# 6. --unsigned without the explicit opt-in
FEED_ALLOW_UNSIGNED= bash "$REPO/scripts/feed-publish.sh" --artifacts "$B" --manifest "$WORK/b.sha256" \
	--tree "$WORK/t6" --channel testing --line 25.12 --arch x86_64 --keys-dir "$WORK/keys/pub" \
	--apk-bin "$APK_BIN" --unsigned > "$WORK/o7" 2>&1
[ "$?" != 0 ] && check "--unsigned needs FEED_ALLOW_UNSIGNED=1" nonzero "$WORK/o7" "UNTRUSTED" \
	|| { echo "FAIL  unsigned NOT refused"; fail=$((fail+1)); }

# 7. published key republished with different material (same name)
bash "$REPO/scripts/feed-publish.sh" --artifacts "$C" --manifest "$WORK/c.sha256" --tree "$T" \
	--channel testing --line 25.12 --arch x86_64 --keys-dir "$WORK/other/pub" \
	--sign-key "$WORK/other/tollgate-testing.sec" --apk-bin "$APK_BIN" > "$WORK/o8" 2>&1
[ "$?" != 0 ] && check "same key name, different material is refused" nonzero "$WORK/o8" "DIFFERENT key material" \
	|| { echo "FAIL  key overwrite NOT refused"; fail=$((fail+1)); }

# 8. retention: the baseline tree holds r1; publish r2 then r3 with --keep 2
publish "$WORK/o9" "$T" "$B" "$WORK/b.sha256" --keep 2 >/dev/null
publish "$WORK/o10" "$T" "$C" "$WORK/c.sha256" --keep 2 >/dev/null
listed=$("$APK_BIN" --allow-untrusted adbdump "$T/testing/25.12/x86_64/packages.adb" 2>/dev/null \
	| awk '/^  - name: /{n=$3} /^    version: /{printf "%s-%s\n", n, $2}' | sort | tr '\n' ' ')
if [ "$listed" = "tollgate-fixture-0.6.0_alpha1-r2 tollgate-fixture-0.6.0_alpha1-r3 " ]; then
	check "--keep 2 keeps the current + previous version, prunes the rest" 0 "$WORK/o10"
else
	echo "FAIL  retention: index lists [$listed]"; fail=$((fail+1))
fi
if [ -f "$T/testing/25.12/x86_64/tollgate-fixture-0.6.0_alpha1-r1.apk" ]; then
	echo "FAIL  retention: r1 was not pruned"; fail=$((fail+1))
else
	check "retention pruned r1 from the tree" 0 "$WORK/o10"
fi

# 9. dry-run changes nothing
before=$(find "$T" -type f | sort | xargs sha256sum 2>/dev/null | sha256sum)
publish "$WORK/o11" "$T" "$A" "$WORK/a.sha256" --dry-run >/dev/null
after=$(find "$T" -type f | sort | xargs sha256sum 2>/dev/null | sha256sum)
[ "$before" = "$after" ] && check "--dry-run changes nothing" 0 "$WORK/o11" "would copy" \
	|| { echo "FAIL  dry-run modified the tree"; fail=$((fail+1)); }

echo
echo "================================================================"
if [ "$fail" -gt 0 ]; then
	echo "feed-publish refusal rules: FAIL — $fail failure(s), $pass passed"
	exit 1
fi
echo "feed-publish refusal rules: PASS — $pass/$((pass)) checks"
echo "apk host tool: $APK_BIN ($("$APK_BIN" --version))"
exit 0
