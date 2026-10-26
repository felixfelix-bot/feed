# Installing `tollgate-wrt` from the runtime feed

This is the **consumption** side of the runtime feed: what an operator or RC
tester types on a router to install, upgrade, pin, roll back and remove
`tollgate-wrt`. The producing side — how the signed index and the package tree
get built, signed and published — is [`feed-index-publishing.md`](feed-index-publishing.md).

Everything below that is described as "measured" was run on a real OpenWrt
userland with the real package manager; the transcripts are committed under
[`docs/evidence/`](evidence/) with their hashes, and the reproduction recipe is
[at the bottom](#9-evidence-and-reproduction).

## 0. Status: read this before handing anyone a URL

**No public host served a runtime feed index on 2026-10-11, and none did on
2026-10-26 either.** Measured from the build host on both dates:

| probe | 2026-10-11 | 2026-10-26 |
|---|---|---|
| `feed.tollgate.me` | DNS NXDOMAIN | DNS NXDOMAIN (`curl` exit 6) |
| `feed.orangesync.tech` | TLS handshake failure (`curl` exit 000) | resolves (`23.182.128.51`), TLS still fails (`curl` exit 35) |
| `https://releases.tollgate.me/feed/<arch>` | HTTP 404 | HTTP 404 |
| `…/feed/<arch>/packages.adb`, `…/Packages.gz`, `…/APKINDEX.tar.gz` | HTTP 404 | HTTP 404 (also 404 under `…/feed/stable/25.12/<arch>/…`) |
| `FreedomTechFeed/feed` releases / tags | 0 releases, 0 tags | 0 releases (`felixfelix-bot/feed` tags are all `archive/*` branch tags, not releases) |

The feed exists as a **working local rehearsal tree plus a committed snapshot**
(`records/`) and as this repository's tooling. So:

- the URL form used in the examples below
  (`https://releases.tollgate.me/feed/<arch>/packages.adb`) is the **planned
  canonical form** — it does not resolve to a live index yet;
- do not give a tester an install command that points at the public host until
  the feed is actually published and re-fetched successfully (see
  [§8](#8-verifying-the-feed-when-it-goes-live)).

The procedure itself is not speculative: each step below was executed against a
real signed index and a real package, and the transcripts are in this repo.

## 1. What the runtime feed is

```
<tree>/keys/<keyname>.pem                       # signing key(s), one file per key
<tree>/<channel>/<line>/<arch>/packages.adb     # the signed index (apk v3)
<tree>/<channel>/<line>/<arch>/<pkg>-<ver>.apk  # the payload(s) the index lists
```

- **channel** — e.g. `testing`, `stable`.
- **line** — the OpenWrt line the packages were built for, e.g. `25.12`.
- **arch** — the target arch, e.g. `aarch64_cortex-a53`, `mipsel_24kc`. It must
  match the router's `DISTRIB_ARCH`, or the package will not install (§7).

The index is `packages.adb` (apk v3). It is signed with an EC P-256 key held
outside the tree; the public half is published under `keys/` and must be
installed on the router before apk will trust anything the index offers.

## 2. Prerequisites

- OpenWrt **25.12.x** (apk-tools 3.x). 24.10 and older are **not supported** by
  this feed — see §6.
- The router needs outbound HTTPS to the feed host.
- The `keys/` public key file for the feed (out-of-band, or fetched from the
  same host over HTTPS on first install).
- Know your arch:

  ```sh
  . /etc/openwrt_release && echo "$DISTRIB_DESCRIPTION $DISTRIB_ARCH"
  ```

### 2.1 The bench GL-MT6000 specifically

The GL-MT6000 is `mediatek-filogic` / **`aarch64_cortex-a53`**, i.e. its
repository line is

```
https://<feed-host>/<channel>/25.12/aarch64_cortex-a53/packages.adb
```

Two things about the bench unit that shape the steps below:

- It has been run on **both** package managers during this project: the bench
  MT6000 was upgraded in place to `0.6.0_rc6-r1` while still on **opkg /
  24.10.2**, and the sibling MT3000 over **apk / 25.12.5** (the project's
  per-arch validation table records both; that file is not on this branch). The
  procedure documented here is the **apk / 25.12** one — a 24.10 MT6000 has to
  be upgraded to 25.12 first, because this *runtime feed* carries no opkg
  artifact at all (§6). That rc6 install used the per-release **asset download**
  lane, which is a different mechanism from the feed.
- `aarch64_cortex-a53` / `mediatek-filogic` covers the MT3000, the MT6000, the
  Cudy WR3000 v1 and the COMFAST CF-WR632AX, so the *asset* is shared — but the
  WR3000's 16 MB of NOR flash cannot hold the default 21 MB payload, and no
  install has been run on the CF-WR632AX. Neither caveat applies to the MT6000
  (128 MB NAND).

### 2.2 Preconditions that must be true before this document's commands work

This is the gate the rest of the document assumes. All three are *upstream* of
the router:

1. **FE2a merged** — the feed build/publish pipeline lands on the branch the
   release is cut from.
2. **A release is tagged and published** — a tag, and release assets attached to
   it. A branch is not a release: `felixfelix-bot/feed` currently carries many
   `archive/*` git tags that are branch archives, and **0 GitHub releases**.
3. **The feed tree is published and re-fetched successfully** — §8's `curl`
   check returns 200 for your `<channel>/<line>/<arch>/packages.adb`.

Until (1)–(3) hold there is **no URL to hand a tester** (§0). The procedure
below was executed against a local signed rehearsal feed, so it is ready the
moment the gate opens; it has not been executed against a public one.

## 3. Install (apk, OpenWrt 25.12.x)

The whole procedure, in order. Output shown is verbatim from the 2026-10-11
x86_64 rehearsal ([evidence](evidence/2026-10-11-install-transcript-x86_64-rehearsal.txt)).

**Step 1 — trust the feed's signing key.**

```sh
wget -O /etc/apk/keys/tollgate-testing.pem https://<feed-host>/keys/tollgate-testing.pem
```

```
wget_exit=0
-rw-r--r--    1 root     root           178 Jun 29 12:59 openwrt-25.12.pem
-rw-r--r--    1 root     root           178 Oct 11 16:30 tollgate-testing.pem
```

The file name under `/etc/apk/keys/` is not significant — the key is matched by
its content. `uclient-fetch` works the same way if `wget` is unavailable.

**Step 2 — point apk at the feed.**

```sh
echo "https://<feed-host>/<channel>/<line>/<arch>/packages.adb" \
  > /etc/apk/repositories.d/tollgate-testing.list
```

```
http://127.0.0.1:8123/testing/25.12/x86_64/packages.adb
```

This line must be the **full URL of the index file**. apk accepts a bare
directory on the command line, but as a *repository line* it appends
`/<arch>/APKINDEX.tar.gz` (the pre-25.12 layout) and the update fails:

```
ERROR: wget: exited with error 8
WARNING: updating and opening http://…/testing/25.12/x86_64/x86_64/APKINDEX.tar.gz: unexpected end of file
1 unavailable, 0 stale; 11247 distinct packages available   # exit=1
```

(measured — [`probe-matrix`](evidence/2026-10-11-probe-matrix-x86_64-rehearsal.txt),
case 2, and the same failure for a 404'd index, case 3).

**Step 3 — refresh the index.**

```sh
apk update
```

```
 [https://downloads.openwrt.org/releases/25.12.5/…/packages.adb]
 …
 [http://127.0.0.1:8123/testing/25.12/x86_64/packages.adb]
OK: 11248 distinct packages available
update_exit=0
```

`OK: … distinct packages available` with exit 0 means every configured
repository, including the feed, was fetched **and signature-verified**. A repo
that fails shows up as `1 unavailable` and makes `apk update` exit 1 — see §7.

**Step 4 — check the package is really offered, and by whom.**

```sh
apk policy tollgate-wrt
apk search -x -v 'tollgate*'
```

```
tollgate-wrt policy:
  0.6.0_alpha2-r1:
    http://127.0.0.1:8123/testing/25.12/x86_64/packages.adb
tollgate-wrt-0.6.0_alpha2-r1 - TollGate - Cashu-powered WiFi Payment Gateway (LOCAL REHEARSAL BUILD)
```

Do this before installing: it is the cheapest way to catch a wrong-arch path, a
stale index or an untrusted repository.

**Step 5 — install.**

```sh
apk add tollgate-wrt
```

```
(1/2) Installing jq (1.8.1-r2)
  Executing jq-1.8.1-r2.post-install
(2/2) Installing tollgate-wrt (0.6.0_alpha2-r1)
OK: 39.1 MiB in 138 packages
add_exit=0
```

`jq` is a declared runtime dependency and is pulled from the standard OpenWrt
feed, so the router needs its normal feeds enabled too. One package installs
both binaries: `tollgate-wrt` (the service) and `tollgate` (the CLI).

**Step 6 — verify what landed.**

```sh
apk list --installed | grep -i tollgate
apk policy tollgate-wrt                 # includes 'lib/apk/db/installed' as a source
apk info -L tollgate-wrt | head
ls -l /usr/bin/tollgate /usr/bin/tollgate-wrt /etc/init.d/tollgate-wrt
```

```
tollgate-wrt-0.6.0_alpha2-r1 x86_64 {tollgate-wrt} (GPL-3.0-only) [installed]
…
-rwxr-xr-x    1 nobody   nogroup   10253038 Sep 12 21:08 /usr/bin/tollgate
-rwxr-xr-x    1 nobody   nogroup   17732119 Sep 12 21:08 /usr/bin/tollgate-wrt
-rwxr-xr-x    1 nobody   nogroup       1380 Sep 12 21:08 /etc/init.d/tollgate-wrt
```

Then start it and let the init script own the process:

```sh
/etc/init.d/tollgate-wrt enable
/etc/init.d/tollgate-wrt start
```

**Step 7 — prove it is actually serving, on the ports it actually serves.**

This is the block to hand a tester, because it is the one part of the procedure
that is easy to get wrong: **there is no `/health` endpoint on `:2121`.** The
service registers only `/`, `/whoami`, `/ln-invoice`, `/balance`, `/usage`,
`/session-state`, `/session/*` and `/identity*`, and Go's mux falls any unknown
path through to the `/` handler — so `wget -qO- http://<router>:2121/health`
returns **HTTP 200 with the same advertisement event `/` serves, byte for
byte**, and would make a dead router look half-alive. Measured on a real
25.12.5 userland
([transcript](evidence/2026-10-26-runtime-verification-x86_64.txt)):

```sh
# 1. the service answered at all: its own advertisement/details event
wget -qO- http://127.0.0.1:2121/ | head -c 120        # want {"kind":10021,...
wget -qO- http://127.0.0.1:2121/whoami                # want mac=<client mac>

# 2. the merchant has an identity, and the wallet it prices in
#    /identity is registered only when owned_identities[0].privatekey yields a
#    usable key. A key that does not, is FATAL at boot: the process exits and
#    :2121 closes with it — so an answer here is proof the merchant came up.
#    Check the SHAPE (a body starting {"npub":"), not a byte count.
wget -qO- http://127.0.0.1:2121/identity              # want {"npub":"npub1...,"ipv4":...
wget -qO- http://127.0.0.1:2121/balance               # want {"status":1,...

# 3. the portal SPA is being served
wget -qO- http://127.0.0.1:2051/splash.html | grep -o '<title>.*</title>'  # want <title>Tollgate Captive Portal</title>

# 4. the CLI agrees, over the unix socket
tollgate health                                       # want: healthy / status: ok
```

Measured answers for each of those, and the ones that are **not** liveness
signals (`/health`, `/healthz`, `/ready` and any other unknown path all return
the `/` handler's body — byte-identical, exit 0). The `id`/`pubkey`/`npub`
values are per-install and the byte counts are per-boot: the `/` body carries
one `price_per_step` tag per mint the wallet came up with, so it moved between
683, 755 and 815 bytes across boots of the same image and config, and the
`/identity` body moves with the length of the npub and the IPv4 string. Match
the **shapes**, never a literal length:

```
GET /          -> {"kind":10021,"id":"…","pubkey":"…   ← one price_per_step tag per live mint
GET /whoami    ->  21 bytes  mac=00:00:00:00:00:00
GET /identity  -> {"npub":"npub1…","ipv4":"100.…       ← starts exactly like this
GET /balance   ->  74 bytes  {"status":1,"session_active":false,"usage":0,"allotment":0,"remaining":0}
GET /usage     ->   5 bytes  -1/-1
GET /health    -> the same body as /   ← the / handler, NOT a health route
```

Ports and paths that matter afterwards (from the vendored `files/` tree; three of
the four `LISTEN` sockets were observed on the real run — `2050` belongs to
nodogsplash, which is not in the minimal test image, so that row is the init
script's configuration and not an observed socket):

| what | where it comes from | value |
|---|---|---|
| service HTTP (`/`, `/whoami`, `/identity`, `/balance`, `/usage`, …) | Go service | TCP **2121**, all interfaces |
| CLI ↔ service socket | Go service | `/var/run/tollgate.sock` (moves to `$TOLLGATE_TEST_CONFIG_DIR/tollgate.sock` only when that env var is set — the CLI prints a `WARNING` when it is) |
| captive portal SPA (pre-auth clients) | `uhttpd.portal` (`99-tollgate-setup`) | TCP **2051**, `home=/etc/tollgate/tollgate-captive-portal-site` |
| nodogsplash redirect stub | `90-tollgate-captive-portal-symlink` | TCP **2050** (`gatewayport`), on `br-lan` |
| admin / LuCI | `uhttpd.main` (`99-tollgate-setup`) | TCP **8080**, `home=/www` |

Two portal facts worth knowing before you debug a "blank portal": the payload
ships `splash.html`, `balance.html`, `welcome.html` and `404.html` but **no
`index.html`**, and `uhttpd.portal` sets `no_dirlists=1` — so `http://<router>:2051/`
is answered by the 404 page (HTTP 200, 3,268 bytes) and the page a pre-auth
client is actually redirected to is `/splash.html`. `curl` is not installed on a
stock 25.12 rootfs; use `wget` or `uclient-fetch` as above.

One asymmetry in `/etc/tollgate/identities.json` is worth knowing before anyone
hand-edits it (both directions measured, §V7/V8 of the transcript): a key that
**parses but is unusable** (`owned_identities: []`, empty string, non-hex, all
zeros) is fatal at boot — the log ends in `Failed to create merchant …` and
`:2121` never opens, which is loud and easy to diagnose. A file that **does not
parse** is not fatal: the service generates a fresh merchant identity, copies the
old file to `/etc/tollgate/config_backups/identities_<ts>_v<ver>.json`, and
starts normally with a **different npub** and only a `WARNING` in the log. So
before editing that file, back it up (and the 12-word seed), and compare
`GET /identity`'s npub after the restart.

## 4. Talking to the running service

The CLI is not standalone: every `tollgate` subcommand talks to the service
over `/var/run/tollgate.sock`. With the service running (real transcript,
2026-09-12, [`evidence`](evidence/2026-09-12-service-cli-transcript.txt)):

```
--- tollgate version ---
version: v0.6.0_alpha2
commit: dcf8c5d
build_time: 2026-09-13T00:00:00Z
go_version: go1.26.0
openwrt_version: OpenWrt 25.12.5 r33051-f5dae5ece4
--- tollgate status ---
running: true
version: TollGate v0.6.0_alpha2
config_ok: true
wallet_ok: true
network_ok: true
--- tollgate health ---
healthy
status: ok
```

Upstream behaviours that look like breakage but are not (all measured):

- `tollgate version` / `status` / `health` fail with
  `dial unix /var/run/tollgate.sock: connect: connection refused` when the
  service is not running — exit 1, and the error text is the diagnosis.
- `tollgate --version` → `Error: unknown flag: --version` (exit 1). The root
  command declares no version flag.
- `tollgate-wrt --version` has no flag parser: it ignores the argument and
  starts the daemon.
- `/etc/init.d/tollgate-wrt status` needs procd/ubus. Outside a real router
  userland it prints `Failed to connect to ubus` and reports `inactive`
  (exit 3) even when the service is up.

## 5. Upgrade, pin, roll back, remove

apk v3's world file is the pin. Measured on a two-version feed
(`0.6.0_alpha2-r1` + `0.6.0_alpha3-r1`); transcript
[`evidence/2026-09-12-world-pin-and-cli-transcript.txt`](evidence/2026-09-12-world-pin-and-cli-transcript.txt).

| goal | command | what happens |
|---|---|---|
| install, tracking the channel | `apk add tollgate-wrt` | world entry is the bare name `tollgate-wrt`; `apk upgrade` follows the feed |
| upgrade | `apk upgrade` | `Upgrading tollgate-wrt (0.6.0_alpha2-r1 -> 0.6.0_alpha3-r1)` |
| roll back to a known-good version | `apk add 'tollgate-wrt=0.6.0_alpha2-r1'` | `Downgrading tollgate-wrt (0.6.0_alpha3-r1 -> 0.6.0_alpha2-r1)`; world becomes `tollgate-wrt=0.6.0_alpha2-r1` |
| release the pin | `apk add tollgate-wrt` | world returns to `tollgate-wrt`; the next `apk upgrade` moves to the newest version again |
| remove | `apk del tollgate-wrt` | `Purging tollgate-wrt (0.6.0_alpha2-r1)`; `/usr/bin/tollgate` and `/usr/bin/tollgate-wrt` are gone |

**The pin survives `apk upgrade`.** With `tollgate-wrt=0.6.0_alpha2-r1` in the
world file, `apk upgrade` leaves the older version installed — that is the
supported rollback path, and it is why an RC tester who hits a bad build can
stay on the good one without touching the feed.

Note for testers: rollback means *older version*, not *older payload of the same
version*. Because `PKG_RELEASE` owns the revision, a re-cut of identical content
must bump `-rN` (see the README's "Version identity") — otherwise apk has no
reason to re-install anything.

### 5.1 Moving to a later feed release

The feed's index is one mutable path per `(channel, line, arch)`; releases land
in it by re-publishing that path, so "upgrading to a later release" is an
`apk update` + `apk upgrade`, not a new repository line:

```sh
apk update                                    # re-fetch + verify the index; expect exit 0
apk policy tollgate-wrt                        # what version is now offered, from which URL
apk upgrade tollgate-wrt                       # package-scoped: only this package moves
# verify (this document's §3 step 7), then:
/etc/init.d/tollgate-wrt restart
tollgate health                                # want: healthy / status: ok
```

- `apk upgrade tollgate-wrt` moves only this package; bare `apk upgrade` takes
  the whole system. Measured: the package-scoped form is accepted
  (`Usage: apk upgrade [<OPTIONS>...] [<PACKAGES>...]`) and an unknown name is a
  real failure — `ERROR: Package 'tollgate-wrt' not found`, **exit 1**. Do not
  swallow that exit code.
- **`apk policy` does not show the world pin.** It lists the versions the
  indexes offer and where each came from; the pin lives in `/etc/apk/world`.
  Measured after pinning `jq=1.8.1-r2`: `apk policy jq` was unchanged, while
  `/etc/apk/world` went from `jq` to `jq=1.8.1-r2`. Read the world file when you
  need to know whether a router is pinned.
- If the world file holds a pin (`tollgate-wrt=0.6.0_alpha2-r1`), `apk upgrade`
  will **not** move it — release the pin first (`apk add tollgate-wrt`), or
  install the target version explicitly.
- To move to a *different channel* (`testing` → `stable`), rewrite the
  repository line (§3 step 2), run `apk update`, then `apk add tollgate-wrt`.
  apk merges indexes from every configured repository and picks the highest
  version, so a mis-typed channel that also exists shows up as
  `apk policy` naming the wrong URL — check that line before upgrading.
- Moving **down** a line (25.12 → 24.10) is not a feed operation at all: there
  is no opkg artifact (§6).

### 5.2 Rollback and removal, in full

```sh
# roll back to the previous version, pinned so `apk upgrade` cannot undo it
apk add 'tollgate-wrt=<previous-version>'
grep tollgate-wrt /etc/apk/world     # want: tollgate-wrt=<previous-version>

# later: release the pin and follow the channel again
apk add tollgate-wrt
grep tollgate-wrt /etc/apk/world     # want: tollgate-wrt

# remove, including the world entry and the two binaries
apk del tollgate-wrt
ls /usr/bin/tollgate /usr/bin/tollgate-wrt        # expect: No such file or directory
```

`apk del` purges the package (measured: `Purging tollgate-wrt (… )`, exit 0,
both binaries gone, the world entry removed). What it does **not** remove is
anything an operator put in a package-owned directory: measured for the purge
case, a file written by hand into the package's own `/usr/share/<pkg>/` survived
`apk del` untouched. So removing `tollgate-wrt` leaves `/etc/tollgate/`
(`config.json`, `install.json`, `identities.json`, `ecash/`) in place — that is
operator data, not package payload, and a reinstall reuses the wallet and
identity. Remove it deliberately if you want a clean identity.

## 6. opkg (24.10 and older): not supported

The feed builds against OpenWrt's Go toolchain, and upstream's module requires
`go >= 1.25` while the 24.10 feed ships Go 1.23.12 — so **no opkg artifact
exists** for this feed. Do not hand a tester a `src/gz` line for it.

What was measured on a real 24.10.8 userland (opkg 38eccbb, transcript
[`evidence/2026-09-13-opkg-24.10-transcript.txt`](evidence/2026-09-13-opkg-24.10-transcript.txt)),
for the day this changes:

- The line form is `src/gz <name> <base-url>` — the **directory**, not a file
  name (opkg appends `Packages.gz` / `Packages.sig` itself), e.g.
  `src/gz tollgate https://<feed-host>/testing/25.12/mipsel_24kc`.
- With `option check_signature` set and no `Packages.sig` on the host, opkg
  prints `Signature file download failed. Remove wrong Signature file.`, then
  `* opkg_download: Failed to download …/Packages.sig, wget returned 8`, and
  `opkg update` exits **1** — but it still writes the unsigned list, and
  `opkg list` exits 0. So a missing opkg signature is a download error, **not** a
  trust refusal: opkg feeds must be signed by policy, not by the tool.
- An index signed only by the feed's own key is not automatically trusted
  either; opkg trusts keys in `/etc/opkg/keys` (or the built-in OpenWrt key).

## 7. Troubleshooting: the messages, and what they mean

All rows are verbatim from the 2026-10-11 probes
([install](evidence/2026-10-11-install-transcript-x86_64-rehearsal.txt),
[probe matrix](evidence/2026-10-11-probe-matrix-x86_64-rehearsal.txt),
[negative controls](evidence/2026-10-11-negative-controls-x86_64-rehearsal.txt)).

| symptom | cause | fix |
|---|---|---|
| `WARNING: updating and opening <url>: UNTRUSTED signature`, `1 unavailable`, `apk update` exit 1 | the index is not signed by any key in `/etc/apk/keys` — key missing, or index published unsigned | install the feed's public key (§3 step 1). **Never** work around it with `--allow-untrusted`. |
| `ERROR: wget: exited with error 8` + `<url>/<arch>/APKINDEX.tar.gz` + `1 unavailable` | repository line is a directory instead of the index file, or the index 404s | use the full `…/packages.adb` URL, and check it with `curl -I` |
| `apk update` says OK, `apk add` says `error: uninstallable` / `arch: mipsel_24kc` | the path served an index built for a different arch | use the `<arch>` path matching `DISTRIB_ARCH` |
| `ERROR: … failed to extract usr/bin/tollgate: Connection aborted`, `1 error`, package not installed | signed index, but the served payload is truncated / not the bytes the index hashes | re-publish; verify with `scripts/feed-verify.sh` (hash-checks every listed package) |
| `ERROR: unable to select packages: tollgate-wrt (no such package): required by: world[tollgate-wrt]` | no readable feed offers it: index untrusted, index unavailable, wrong arch, or not published | run §3 steps 3–4; the `apk policy` output names the source, or says nothing |
| `dial unix /var/run/tollgate.sock: connect: connection refused` | the service is not running | `/etc/init.d/tollgate-wrt start` |
| `Failed to connect to ubus` from `/etc/init.d/tollgate-wrt status` | no procd (container/lab userland) | check the socket and the HTTP port instead |
| you checked `wget -qO- :2121/health`, got `200`, and the router is still dead | **there is no `/health` route** — the `/` handler answers every unknown path with its own advertisement body, byte for byte | use §3 step 7: `/` + `/whoami` + `/identity` + `/balance`, then `tollgate health` over the socket |
| service will not stay up; log ends with `Failed to create merchant … owned identity not found` / `private key is zero` / `Sign called with invalid secret key` | `/etc/tollgate/identities.json` has no usable merchant key — **fatal at boot**, so `:2121` never opens (not a missing route, a dead process) | restore the file from backup, or delete it and let the service generate a fresh merchant identity on the next start |
| `tollgate: not found` where you expected it to work | the router has no `tollgate` CLI, or you are on a host that never installed it | the CLI ships in the same package as the service; check `apk info -L tollgate-wrt` |

Two rules worth repeating to anyone scripting this:

1. **`--allow-untrusted` is never the answer.** An unsigned index is refused for
   a reason (case 7 in the probe matrix: `UNTRUSTED signature`, `apk update`
   exit 1, and the feed contributes no packages at all).
2. **Watch `apk update`'s exit code, not just its last line.** In a router with
   8 stock repos configured, one broken feed line shows up only as
   `1 unavailable` and an exit code change.

## 8. Verifying the feed when it goes live

Before giving a tester a URL, from a machine that can reach the published host:

```sh
curl -fsS -o /dev/null -w '%{http_code}\n' https://<feed-host>/<channel>/<line>/<arch>/packages.adb   # expect 200
sh scripts/feed-verify.sh …     # re-fetches the published index, hash-checks every package it lists
```

and then the cheapest end-to-end proof on a real router: §3 steps 1–7, with
`apk policy tollgate-wrt` naming the public URL rather than `lib/apk/db/installed`.

Note that `curl` is **absent** from a stock OpenWrt 25.12 rootfs (measured), so
anything you paste into a router session must use `wget` or `uclient-fetch`;
`curl -I` in this document is a *build-host* command.

## 9. Evidence and reproduction

Committed under [`docs/evidence/`](evidence/). The 2026-10-11 files were produced
on host `CobradorWave` inside a container imported from
`openwrt-25.12.5-x86-64-rootfs.tar.gz` — i.e. a real OpenWrt 25.12.5
(`r33051-f5dae5ece4`, x86_64) userland with real `apk-tools 3.0.5` — against a
local signed rehearsal feed on `127.0.0.1:8123`, channel `testing`, line `25.12`,
arch `x86_64`, index sha256
`50d39d450b8ce75422be931965a7bda7ba956e6563d6dd6f6070b2268e3dcb66` (388 bytes)
listing `tollgate-wrt-0.6.0_alpha2-r1.apk` (15,238,869 bytes) — a **local
rehearsal build**, not the reference artifact in `records/`. The two 2026-10-26
files were produced on host `x280` in the same kind of container
(`owrt2512:docs26`), against the built `tollgate-wrt` binary and this repo's
packaged portal payload, with no feed involved.

| file | sha256 | what it shows |
|---|---|---|
| `evidence/2026-10-11-install-transcript-x86_64-rehearsal.txt` | `69ff205c1fc897a4…` | key → repository line → `apk update` → `apk policy` → `apk add` → provenance → unsigned refusal → `apk del` |
| `evidence/2026-10-11-probe-matrix-x86_64-rehearsal.txt` | `06067c1d109cf503…` | 7 cases: control, directory form, 404 index, wrong-arch index, same index bytes at another path, truncated payload, unsigned index |
| `evidence/2026-10-11-negative-controls-x86_64-rehearsal.txt` | `bdbd8bde2ecd8fa4…` | the two negatives in fresh containers: truncated payload, unsigned index |
| `evidence/2026-09-12-world-pin-and-cli-transcript.txt` | `0a9dc07b126e0083…` | world-pin semantics (install/upgrade/downgrade/release) + CLI without a running service |
| `evidence/2026-09-12-service-cli-transcript.txt` | `db1dc1c13b94eccd…` | successful install, service started by hand, `tollgate version/status/health` answers |
| `evidence/2026-09-13-opkg-24.10-transcript.txt` | `f8ef358f071677d3…` | 24.10.8 opkg: `src/gz` line, missing `Packages.sig`, `opkg update` exit 1, `opkg list` exit 0 |
| `evidence/2026-10-26-runtime-verification-x86_64.txt` | `4932ff9c887dbb81…` | the **runtime** side of §3 step 7 on a real 25.12.5 userland: `:2121` answers `{"kind":10021,…}`, `/health` is the `/` handler and not a health route, `/whoami` `/identity` `/balance` `/usage` answers, `:2051` portal payload served, `:8080` admin answers, `curl` absent, and every `identities.json` state a tester can reach (unusable key = fatal at boot; a malformed file = silently replaced identity) |
| `evidence/2026-10-26-apk-semantics-x86_64.txt` | `3381befbdffae603…` | the apk behaviours §5.1/§5.2 rely on: `apk upgrade <pkg>` is accepted and **exits 1** on an unknown name, `apk policy` does **not** show the world pin (the world file does), `apk del` removes the world entry and the indexed files but leaves operator-written files in a package-owned directory |

Reproduction (the rehearsal, on a Linux host with Docker):

```sh
docker import openwrt-25.12.5-x86-64-rootfs.tar.gz owrt2512:local
( cd serve && python3 -m http.server 8123 --bind 127.0.0.1 & )     # serves keys/ + <channel>/…
docker run --rm --network host -it owrt2512:local sh
#   wget -O /etc/apk/keys/<key>.pem http://127.0.0.1:8123/keys/<key>.pem
#   echo "http://127.0.0.1:8123/testing/25.12/x86_64/packages.adb" > /etc/apk/repositories.d/tollgate.list
#   apk update && apk add tollgate-wrt
```

The two 2026-10-26 captures are reproducible from this repo alone (no feed
needed): stage the built binary and the packaged portal payload into a container
and run
[`evidence/2026-10-26-runtime-verification-x86_64.sh`](evidence/2026-10-26-runtime-verification-x86_64.sh)
and
[`evidence/2026-10-26-apk-semantics-x86_64.sh`](evidence/2026-10-26-apk-semantics-x86_64.sh).

### What this evidence does **not** prove

- It is an **x86_64** run. The router target (`aarch64_cortex-a53` for a
  GL-MT6000) uses the same repository-line and pinning mechanics, but its own
  index and payloads — verify the arch path is right, as §7 describes.
- It is a **local rehearsal feed**, not the public one. No live host serves an
  index today (§0), and nothing here proves the public tree's contents or its
  TLS configuration.
- It does not prove anything on a **physical router** (procd, ubus, the captive
  portal on 2050, the MT6000): the container has no procd, which is why the
  service was exercised through its socket and HTTP port instead.
- The 2026-10-26 capture stages the **packaged portal payload** and the built
  binary by hand; it does not prove that `apk add` + the package's `postinst`
  wire them up on a real router, and the `tollgate health` line comes from the
  2026-09-12 transcript rather than from that container (the `tollgate` CLI
  package was not staged). The apk-semantics capture uses `jq` as a stand-in
  for `tollgate-wrt`, because it asserts apk's own world/policy/purge behaviour
  rather than anything package-specific.

## See also

- [`feed-index-publishing.md`](feed-index-publishing.md) — building, signing and
  publishing the index this doc consumes.
- [`../README.md`](../README.md) — supported matrix, version-spelling rules,
  the `src-git` **build** feed (a different thing from this runtime feed).
- [`../records/README.md`](../records/README.md) — the publish record and the
  committed tree snapshot, including the payload-mirroring gap.
