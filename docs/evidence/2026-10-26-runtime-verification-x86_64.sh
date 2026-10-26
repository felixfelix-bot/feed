#!/bin/sh
# t_d41ef5b5 runtime-verification capture.
# Runs INSIDE an OpenWrt 25.12.5 x86_64 userland (podman container imported from
# openwrt-25.12.5-x86-64-rootfs.tar.gz) with the real tollgate-wrt binary at
# /lab/tollgate-wrt and the packaged portal payload staged at /lab/site
# (net/tollgate-wrt/files/tollgate-captive-portal-site + net/tollgate-wrt/portal-assets/assets).
set -u

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
  netstat -ltn 2>/dev/null | grep -q ':2121 ' && break
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
echo "after starting uhttpd main(:8080) + portal(:2051):"
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
  printf '  GET %-9s -> wget_exit=%s bytes=%-5s body[0:40]=%s\n' \
    "$p" "$?" "$(wc -c < /tmp/v.out)" "$(head -c 40 /tmp/v.out | tr -d '\n')"
done
echo "  The mux registers only / /whoami /ln-invoice /balance /usage /session-state"
echo "  /session/* /identity*, so every unknown path falls through to the / handler:"
echo "  /health returns the SAME 815-byte event with exit 0 as / does. There is no"
echo "  health endpoint to curl. (tollgate-module-basic-go src/main.go:1901-1990)"

echo
echo "== V3  the routes you CAN use as a liveness/configuration probe =="
for p in /whoami /identity /balance /usage; do
  wget -qO /tmp/v.out "http://127.0.0.1:2121$p" 2>/tmp/v.err
  printf '  GET %-9s -> wget_exit=%s bytes=%-4s %s\n' \
    "$p" "$?" "$(wc -c < /tmp/v.out)" "$(head -c 96 /tmp/v.out | tr -d '\n')"
done
echo "  /identity answers only once the merchant exists (mint-dependent routes are"
echo "  wrapped in requireStarted); /whoami answers even while the wallet loads."

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
echo "  / is not an index page: the payload ships splash.html, balance.html,"
echo "  welcome.html, 404.html and no index.html, and uhttpd.portal sets"
echo "  no_dirlists=1, so / is answered by the 404 handler (3268 bytes, HTTP 200)."
echo "  The page a pre-auth client is actually redirected to is /splash.html."

echo
echo "== V6  admin uhttpd on :8080 =="
wget -qO /tmp/a.out http://127.0.0.1:8080/ 2>/tmp/a.err
echo "  GET / -> wget_exit=$? bytes=$(wc -c < /tmp/a.out) body[0:50]=$(head -c 50 /tmp/a.out | tr -d '\n')"

echo
echo "== stop =="
kill $TG_PID 2>/dev/null
pkill uhttpd 2>/dev/null
sleep 1
echo "done"
