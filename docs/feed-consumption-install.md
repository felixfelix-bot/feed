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

**No public host served a runtime feed index on 2026-10-11.** Measured from the
build host on that date:

| probe | result |
|---|---|
| `feed.tollgate.me` | DNS NXDOMAIN |
| `feed.orangesync.tech` | TLS handshake failure (`curl` exit 000) |
| `https://releases.tollgate.me/feed/<arch>` | HTTP 404 |
| `…/feed/<arch>/packages.adb`, `…/Packages.gz`, `…/APKINDEX.tar.gz` | HTTP 404 |
| `FreedomTechFeed/feed` releases / tags | 0 releases, 0 tags |

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

Ports and paths that matter afterwards (from the vendored `files/` tree):

| what | value |
|---|---|
| captive portal | TCP 2050 (`nodogsplash gatewayport`), on `br-lan` |
| service HTTP | TCP 2121 |
| CLI ↔ service socket | `/var/run/tollgate.sock` |

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

## 6. opkg (24.10 and older): not supported

The feed builds against OpenWrt's Go toolchain, and upstream's module requires
`go >= 1.25` while the 24.10 feed ships Go 1.23.12 — so **no opkg artifact
exists** for this feed. Do not hand a tester a `src/gz` line for it.

What was measured on a real 24.10.8 userland (opkg 38eccbb, transcript
[`evidence/2026-09-13-opkg-24.10-transcript.txt`](evidence/2026-09-13-opkg-24.10-transcript.txt)),
for the day this changes:

- The line form is `src/gz <name> <base-url>` — the **directory**, not a file
  name (opkg appends `Packages.gz` / `Packages.sig` itself).
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

and then the cheapest end-to-end proof on a real router: §3 steps 1–6, with
`apk policy tollgate-wrt` naming the public URL rather than `lib/apk/db/installed`.

## 9. Evidence and reproduction

Committed under [`docs/evidence/`](evidence/). All 2026-10-11 files were produced
on host `CobradorWave` inside a container imported from
`openwrt-25.12.5-x86-64-rootfs.tar.gz` — i.e. a real OpenWrt 25.12.5
(`r33051-f5dae5ece4`, x86_64) userland with real `apk-tools 3.0.5` — against a
local signed rehearsal feed on `127.0.0.1:8123`, channel `testing`, line `25.12`,
arch `x86_64`, index sha256
`50d39d450b8ce75422be931965a7bda7ba956e6563d6dd6f6070b2268e3dcb66` (388 bytes)
listing `tollgate-wrt-0.6.0_alpha2-r1.apk` (15,238,869 bytes) — a **local
rehearsal build**, not the reference artifact in `records/`.

| file | sha256 | what it shows |
|---|---|---|
| `evidence/2026-10-11-install-transcript-x86_64-rehearsal.txt` | `69ff205c1fc897a4…` | key → repository line → `apk update` → `apk policy` → `apk add` → provenance → unsigned refusal → `apk del` |
| `evidence/2026-10-11-probe-matrix-x86_64-rehearsal.txt` | `06067c1d109cf503…` | 7 cases: control, directory form, 404 index, wrong-arch index, same index bytes at another path, truncated payload, unsigned index |
| `evidence/2026-10-11-negative-controls-x86_64-rehearsal.txt` | `bdbd8bde2ecd8fa4…` | the two negatives in fresh containers: truncated payload, unsigned index |
| `evidence/2026-09-12-world-pin-and-cli-transcript.txt` | `0a9dc07b126e0083…` | world-pin semantics (install/upgrade/downgrade/release) + CLI without a running service |
| `evidence/2026-09-12-service-cli-transcript.txt` | `db1dc1c13b94eccd…` | successful install, service started by hand, `tollgate version/status/health` answers |
| `evidence/2026-09-13-opkg-24.10-transcript.txt` | `f8ef358f071677d3…` | 24.10.8 opkg: `src/gz` line, missing `Packages.sig`, `opkg update` exit 1, `opkg list` exit 0 |

Reproduction (the rehearsal, on a Linux host with Docker):

```sh
docker import openwrt-25.12.5-x86-64-rootfs.tar.gz owrt2512:local
( cd serve && python3 -m http.server 8123 --bind 127.0.0.1 & )     # serves keys/ + <channel>/…
docker run --rm --network host -it owrt2512:local sh
#   wget -O /etc/apk/keys/<key>.pem http://127.0.0.1:8123/keys/<key>.pem
#   echo "http://127.0.0.1:8123/testing/25.12/x86_64/packages.adb" > /etc/apk/repositories.d/tollgate.list
#   apk update && apk add tollgate-wrt
```

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

## See also

- [`feed-index-publishing.md`](feed-index-publishing.md) — building, signing and
  publishing the index this doc consumes.
- [`../README.md`](../README.md) — supported matrix, version-spelling rules,
  the `src-git` **build** feed (a different thing from this runtime feed).
- [`../records/README.md`](../records/README.md) — the publish record and the
  committed tree snapshot, including the payload-mirroring gap.
