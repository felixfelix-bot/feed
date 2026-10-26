#!/bin/sh
# t_d41ef5b5 runtime-verification capture.
# Runs INSIDE an OpenWrt 25.12.5 x86_64 userland (podman container imported from
# openwrt-25.12.5-x86-64-rootfs.tar.gz) with the real tollgate-wrt binary at
# /lab/tollgate-wrt and the packaged portal payload staged at /lab/site
# (net/tollgate-wrt/files/tollgate-captive-portal-site + net/tollgate-wrt/portal-assets/assets).
#
# Purpose: measure the "verify what landed" block of feed-consumption-install.md
# — which HTTP checks actually answer, which do not exist, and what the service
# does with each state of identities.json that a tester can end up in.
set -u

port_busy() { netstat -ltn 2>/dev/null | grep -q ':2121 '; }
wait_port_free() {
  n=0
  while port_busy && [ $n -lt 20 ]; do n=$((n+1)); sleep 1; done
  port_busy && return 1 || return 0
}

echo "== environment =="
. /etc/openwrt_release
echo "release:  $DISTRIB_DESCRIPTION"
echo "arch:     $DISTRIB_ARCH"
echo "pkg mgr:  $(apk --version)"
echo "http clients present:"
for c in curl wget uclient-fetch; do
  if command -v "$c" >/dev/null 2>&1; then echo "  $c: $(command -v "$c")"; else echo "  $c: ABSENT"; fi
done
echo "nodogsplash: $(command -v nodogsplash || echo ABSENT)"
echo "procd/ubus:  $(command -v ubus || echo ABSENT)"
echo "binary: $(sha256sum /lab/tollgate-wrt | cut -d' ' -f1)  $(ls -l /lab/tollgate-wrt | awk '{print $5}') bytes"

echo
echo "== start the service (no procd: run the daemon directly, as the init script would) =="
cp /lab/tollgate-wrt /usr/bin/tollgate-wrt
mkdir -p /tmp/tg
TOLLGATE_TEST_CONFIG_DIR=/tmp/tg /usr/bin/tollgate-wrt >/tmp/tg.log 2>&1 &
TG_PID=$!
echo "tollgate-wrt pid=$TG_PID"
i=0
while [ $i -lt 40 ]; do
  port_busy && break
  i=$((i+1)); sleep 1
done
echo "listener appeared after ${i}s:"
netstat -ltn | grep -E ':(2121|2051|8080|2050) ' || echo "  (none)"

echo
echo "== the two uhttpd instances the package configures (files/etc/uci-defaults/99-tollgate-setup) =="
# uhttpd.main   -> listen 0.0.0.0:8080, home=/www
uhttpd -f -h /www -p 0.0.0.0:8080 -N 100 -K 20 >/tmp/uh-main.log 2>&1 &
# uhttpd.portal -> listen 0.0.0.0:2051, home=/etc/tollgate/tollgate-captive-portal-site,
#                  no_dirlists=1, no index.html in the payload
uhttpd -f -h /lab/site -p 0.0.0.0:2051 -N 100 -K 20 -D -E /404.html >/tmp/uh-portal.log 2>&1 &
sleep 3
echo "LISTEN sockets after starting uhttpd main(:8080) + portal(:2051):"
netstat -ltn | grep -E ':(2121|2051|8080|2050) '

echo
echo "== V1  service HTTP :2121 answers the details/advertisement event =="
echo "\$ wget -qO- http://127.0.0.1:2121/ | head -c 120"
wget -qO /tmp/v1.out http://127.0.0.1:2121/; echo "wget_exit=$?"
head -c 120 /tmp/v1.out; echo
echo "bytes=$(wc -c < /tmp/v1.out)"
echo "\$ the same body's kind tag:"
grep -o '"kind":[0-9]*' /tmp/v1.out | head -1

echo
echo "== V2  there is NO /health route on :2121: a 200 there proves nothing =="
for p in / /health /healthz /ready /nope; do
  wget -qO /tmp/v.out "http://127.0.0.1:2121$p" 2>/tmp/v.err
  printf '  GET %-9s -> wget_exit=%s bytes=%-5s price_tags=%s body[0:40]=%s\n' \
    "$p" "$?" "$(wc -c < /tmp/v.out)" "$(grep -o 'price_per_step' /tmp/v.out | wc -l)" "$(head -c 40 /tmp/v.out | tr -d '\n')"
done
echo "  The mux registers only / /whoami /ln-invoice /balance /usage /session-state"
echo "  /session/* /identity, so every unknown path falls through to the / handler:"
echo "  /health returns the SAME body with exit 0 as / does — byte for byte,"
echo "  whatever that body happens to be. There is no health endpoint to curl."
echo "  (tollgate-module-basic-go src/main.go:1901-1992)"
echo "  NOTE the length is not a constant, and it is not even stable across boots of"
echo "  the same image. The body carries one price_per_step tag per mint the wallet"
echo "  came up with, and which mints come up varies, so both the tag count and the"
echo "  length move. Measured across boots of this image against the same config"
echo "  (7 mints listed): 683 bytes / 4 tags, 755 / 5, 815 / 6 — the per-tag cost"
echo "  follows the mint URL's own length, so there is no fixed byte-per-tag either."
echo "  Compare the SHAPE — {\"kind\":10021,... at the front, and /health returning"
echo "  the byte-identical body — never a literal length."

echo
echo "== V3  the routes you CAN use as a liveness/configuration probe =="
for p in /whoami /identity /balance /usage; do
  wget -qO /tmp/v.out "http://127.0.0.1:2121$p" 2>/tmp/v.err
  printf '  GET %-9s -> wget_exit=%s bytes=%-4s %s\n' \
    "$p" "$?" "$(wc -c < /tmp/v.out)" "$(head -c 96 /tmp/v.out | tr -d '\n')"
done
echo "  /whoami, /balance and /usage answer on a booted service. /identity is"
echo "  registered only when owned_identities[0].privatekey yields a usable key"
echo "  (src/main.go:1965-1990) — see V7 for the states a tester lands in."
echo "  The byte count is NOT a constant either: the npub and the ipv4 string are"
echo "  per-install. Match the SHAPE — a body that STARTS {\"npub\":\" — never a"
echo "  literal length, and never 'not 815' (see the V2 note on body length)."

echo
echo "== V4  the CLI <-> service socket while the service runs =="
ls -l /var/run/tollgate.sock 2>&1
echo "  the service's own log line naming the socket it listens on:"
grep -i "CLI server" /tmp/tg.log | sed 's/\x1b\[[0-9;]*m//g'
echo "  (\`tollgate health\` speaks to the service over that socket. This container"
echo "   sets TOLLGATE_TEST_CONFIG_DIR, which is the ONE case where the socket"
echo "   moves off /var/run — matching the CLI's own resolution rule. Without that"
echo "   env var both sides use /var/run/tollgate.sock, and the tollgate CLI"
echo "   package was not staged here, so the CLI output quoted in the doc comes"
echo "   from the 2026-09-12 transcript.)"

echo
echo "== V5  portal SPA on :2051 =="
for p in / /splash.html /balance.html /welcome.html /manifest.json /assets/index-DxBkINUB.js; do
  wget -qO /tmp/p.out "http://127.0.0.1:2051$p" 2>/tmp/p.err
  printf '  GET %-28s -> wget_exit=%s bytes=%-7s body[0:40]=%s\n' \
    "$p" "$?" "$(wc -c < /tmp/p.out)" "$(head -c 40 /tmp/p.out | tr -d '\n')"
done
echo "  the check the doc gives a tester (title, not the DOCTYPE — the payload"
echo "  is not minified, so line 1 of splash.html is the doctype and the title"
echo "  sits further down):"
printf '  $ wget -qO- http://127.0.0.1:2051/splash.html | grep -o "<title>.*</title>"\n  '
wget -qO- http://127.0.0.1:2051/splash.html | grep -o '<title>.*</title>'
echo "  grep_exit=$?"
echo "  / is not an index page: the payload ships splash.html, balance.html,"
echo "  welcome.html, 404.html and no index.html, and uhttpd.portal sets"
echo "  no_dirlists=1, so / is answered by the 404 handler (3268 bytes, HTTP 200)."
echo "  The page a pre-auth client is actually redirected to is /splash.html."

echo
echo "== V6  admin uhttpd on :8080 =="
wget -qO /tmp/a.out http://127.0.0.1:8080/ 2>/tmp/a.err
echo "  GET / -> wget_exit=$? bytes=$(wc -c < /tmp/a.out) body[0:50]=$(head -c 50 /tmp/a.out | tr -d '\n')"

echo
echo "== V7  each identities.json state a tester can end up in =="
echo "  Same binary, fresh config dir, ONE service at a time: the previous case is"
echo "  killed and port 2121 confirmed free before the next starts. (An earlier run"
echo "  of this script read 0s in that column because the previous daemon was still"
echo "  up — which is why every case now waits for the port to drain.)"
kill $TG_PID 2>/dev/null
pkill -f 'usr/bin/tollgate-wrt' 2>/dev/null
pkill uhttpd 2>/dev/null
sleep 2
wait_port_free || echo "  WARNING: :2121 still busy, cases below are unreliable"

idcase() {
  label="$1"; body="$2"
  dir="/tmp/id-$(echo "$label" | tr -c 'a-z0-9' '-')"
  rm -rf "$dir"; mkdir -p "$dir"
  if [ "$body" != "ABSENT" ]; then
    printf '%s' "$body" > "$dir/identities.json"
    chmod 600 "$dir/identities.json"
  fi
  TOLLGATE_TEST_CONFIG_DIR="$dir" /usr/bin/tollgate-wrt >"/tmp/id.log" 2>&1 &
  pid=$!
  n=0
  while [ $n -lt 25 ]; do
    port_busy && break
    n=$((n+1)); sleep 1
  done
  if port_busy; then
    wget -qO /tmp/id.out http://127.0.0.1:2121/identity 2>/dev/null
    printf '  %-42s listener +%ss  GET /identity exit=%s bytes=%-4s %s\n' \
      "$label" "$n" "$?" "$(wc -c < /tmp/id.out)" "$(head -c 42 /tmp/id.out | tr -d '\n')"
  else
    printf '  %-42s NO listener  %s\n' "$label" "$(grep -o 'Failed to create merchant.*' /tmp/id.log | head -1 | sed 's/\x1b\[[0-9;]*m//g')"
  fi
  if [ ! -f "$dir/identities.json" ]; then
    echo "      (boot created identities.json: $(wc -c < "$dir/identities.json" 2>/dev/null) bytes — a generated merchant key)"
  fi
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  wait_port_free || echo "      WARNING: :2121 did not drain"
  sleep 1
}
idcase "no identities.json (stock first boot)" "ABSENT"
idcase "owned_identities: []" '{"config_version":"v0.0.1","owned_identities":[],"public_identities":[]}'
idcase "privatekey: empty string" '{"config_version":"v0.0.1","owned_identities":[{"name":"merchant","privatekey":""}],"public_identities":[]}'
idcase "privatekey: not hex" '{"config_version":"v0.0.1","owned_identities":[{"name":"merchant","privatekey":"zzzz"}],"public_identities":[]}'
idcase "privatekey: all zeros" '{"config_version":"v0.0.1","owned_identities":[{"name":"merchant","privatekey":"0000000000000000000000000000000000000000000000000000000000000000"}],"public_identities":[]}'
echo "  => reading the column: every state either SERVES with /identity working,"
echo "     or the process exits and takes :2121 with it. There is no observable"
echo "     state where the service runs but the /identity route is absent."
echo "  => and note the second footgun (measured separately): a malformed or"
echo "     wrong-version identities.json is NOT fatal — it is silently replaced"
echo "     with a freshly generated identity and the old file is copied to"
echo "     /etc/tollgate/config_backups/identities_<ts>_v<ver>.json. The npub"
echo "     changes. A tester who hand-edits that file and mistypes it loses the"
echo "     merchant identity on the next start, with only a Warn in the log."

echo
echo "== V8  what a malformed identities.json actually does (identity loss) =="
echo "  Known key in the file, boot, record the npub; then truncate the file and"
echo "  boot again. This is the state a tester lands in after a bad hand-edit."
K="c767c5ded34207f148c5c7826e3082ed01554a418d99bcdf93002ddd1cc45942"
V8=/tmp/v8; rm -rf "$V8"; mkdir -p "$V8"
printf '{"config_version":"v0.0.1","owned_identities":[{"name":"merchant","privatekey":"%s"}]}' "$K" > "$V8/identities.json"
chmod 600 "$V8/identities.json"
v8boot() {
  TOLLGATE_TEST_CONFIG_DIR="$V8" /usr/bin/tollgate-wrt >"$V8.log" 2>&1 &
  p=$!
  n=0; while [ $n -lt 30 ]; do port_busy && break; n=$((n+1)); sleep 1; done
  sleep 2
  wget -qO /tmp/v8.out http://127.0.0.1:2121/identity 2>/dev/null
  grep -o '"npub":"[a-z0-9]*"' /tmp/v8.out | head -1
  kill $p 2>/dev/null; wait $p 2>/dev/null
  wait_port_free
  sleep 1
}
echo "  key written by hand: $K"
printf '  npub before: '; v8boot
printf '{"owned_identities": [ brok' > "$V8/identities.json"
rm -f "$V8.log"
printf '  npub after:  '; v8boot
echo "  key now in identities.json: $(grep -o '[0-9a-f]\{64\}' "$V8/identities.json" | head -1)"
echo "  log lines naming the replacement (verbatim, both from the same boot log):"
grep -o "WARNING: Invalid 'identities'.*" "$V8.log" | head -1 | sed 's/^/    /'
grep -o 'identity: /identity and /identity/reveal-seed routes registered.*' "$V8.log" | head -1 \
  | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^/    /'
echo "  (the WARNING comes from the plain logger before the service is up; it is the"
echo "   only signal a tester gets — a WARNING, not an error)"
echo "  backups written (hardcoded /etc/tollgate/config_backups, NOT the test dir):"
ls -l /etc/tollgate/config_backups 2>&1 | tail -2 | sed 's/^/    /'
echo "  the original key is not in the backup (it was never written by the service):"
if grep -rq "$K" /etc/tollgate/config_backups 2>/dev/null; then echo "    present"; else echo "    absent — the hand-written key is gone from the box"; fi
echo "  => so: a parse-level mistake costs the identity silently. Warn testers to"
echo "     back up /etc/tollgate/identities.json (and the 12-word seed) before"
echo "     editing it, and to compare the npub after a restart."

echo
echo "== stop =="
pkill -f 'usr/bin/tollgate-wrt' 2>/dev/null
pkill uhttpd 2>/dev/null
sleep 1
echo "done"
