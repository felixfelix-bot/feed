#!/usr/bin/env bash
# Regression test for verify-apk.sh (FD3 aarch64 artifact verifier).
#
#   bash tools/fd3-apk/test-verify-apk.sh
#
# Assertions:
#   T1  verify-apk.sh exists and is executable
#   T2  it accepts the real .apk and reports arch aarch64_cortex-a53
#   T3  it reports the sha256 of the artifact it verified
#   T4  it REJECTS a truncated/corrupt file (exit != 0)
#
# RED/GREEN: this test is expected to fail until verify-apk.sh is added.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$HERE/verify-apk.sh"
ARTIFACT="${ARTIFACT:-/home/c03rad0r/worktrees/fd3-upstream-build/dist/tollgate-wrt_main.98.040dd7fa_aarch64_cortex-a53.apk}"
EXPECTED_ARCH="${EXPECTED_ARCH:-aarch64_cortex-a53}"

pass=0
fails=0
ok()   { pass=$((pass + 1));  printf 'ok   - %s\n' "$1"; }
bad()  { fails=$((fails + 1)); printf 'FAIL - %s\n' "$1"; }

printf '# test: verify-apk.sh\n'

# T1 -------------------------------------------------------------------------
if [ -x "$VERIFY" ]; then
    ok "T1 verify-apk.sh present and executable ($VERIFY)"
else
    bad "T1 verify-apk.sh missing or not executable at $VERIFY"
    printf '\n%d passed, %d failed\n' "$pass" "$fails"
    exit 1
fi

# T2/T3 ----------------------------------------------------------------------
if [ ! -f "$ARTIFACT" ]; then
    bad "T2 artifact under test not found: $ARTIFACT"
else
    out="$("$VERIFY" "$ARTIFACT" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "T2 verifier accepts $ARTIFACT (exit 0)"
    else
        bad "T2 verifier rejected a valid artifact (exit $rc)"
        printf '%s\n' "$out" | sed 's/^/       | /'
    fi
    if printf '%s\n' "$out" | grep -q "^arch: $EXPECTED_ARCH$"; then
        ok "T2b reported arch is $EXPECTED_ARCH"
    else
        bad "T2b reported arch is not $EXPECTED_ARCH"
    fi
    want="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
    if printf '%s\n' "$out" | grep -q "$want"; then
        ok "T3 printed sha256 matches sha256sum ($want)"
    else
        bad "T3 printed sha256 does not match sha256sum ($want)"
    fi
    # T5: the CLI must never pass provenance silently — it either carries the
    # version marker or the verifier says so out loud.
    if printf '%s\n' "$out" | grep -q "provenance: tollgate contains"; then
        if printf '%s\n' "$out" | grep -qE "provenance: tollgate contains .* x[1-9]"; then
            ok "T5 CLI provenance attested (version marker present)"
        elif printf '%s\n' "$out" | grep -q "^WARN: usr/bin/tollgate carries no version marker"; then
            ok "T5 CLI provenance gap reported loudly (WARN), not silently passed"
        else
            bad "T5 CLI provenance neither attested nor warned about"
        fi
    else
        bad "T5 verifier did not report CLI provenance at all"
    fi
fi

# T4 -------------------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if [ -f "$ARTIFACT" ]; then
    head -c 4096 "$ARTIFACT" > "$tmp/truncated.apk"
    "$VERIFY" "$tmp/truncated.apk" >"$tmp/out.txt" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        ok "T4 truncated file rejected (exit $rc)"
    else
        bad "T4 truncated file was ACCEPTED (exit 0) — verifier is not checking the payload"
    fi
else
    bad "T4 skipped: no artifact to truncate"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fails"
[ "$fails" -eq 0 ]
