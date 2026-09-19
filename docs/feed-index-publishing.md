# Runtime feed: index generation, signing, atomic publish

This is the **runtime (binary) feed** half of the project: the thing a router's
package manager reads. It is deliberately separate from the `src-git` build
feed in the README — a router does not clone this repo, it fetches an *index*
over HTTPS and installs packages from it.

```
<tree>/keys/<name>.pem                     apk  public key  (one curl on the router)
<tree>/keys/<name>.pub                     opkg usign public key (opkg-key add)
<tree>/<channel>/<line>/<arch>/packages.adb        apk  index  (mutable path)
<tree>/<channel>/<line>/<arch>/<pkg>-<ver>.apk     apk  packages (immutable names)
<tree>/<channel>/<line>/<arch>/Packages[.gz|.sig]  opkg index (mutable path)
<tree>/<channel>/<line>/<arch>/<pkg>_<ver>_<arch>.ipk
```

`<channel>` is the RC separation mechanism (`prod`, `testing`) — a **path**, not
a git branch, because branches are invisible to routers. Testing gets its own
path, its own index and its own key; reverting a tester is deleting one line.

## Tools

| script | who runs it | what it does |
|---|---|---|
| `scripts/feed-manifest.sh` | the BUILD job | records `<sha256>  <file>` for every package, and refuses an unversioned filename |
| `scripts/get-host-apk-tools.sh` | a human or CI, once | extracts the SDK's **host** `apk` (with `mkndx`) and `usign` into `.feed-tools/apk/bin/` |
| `scripts/feed-keygen.sh` | a human, once per channel | `--type ec` (apk) or `--type usign` (opkg) keypair |
| `scripts/feed-publish.sh` | the publish job, or a human | verify → stage → prune → index → sign → atomic rename → publish packages-then-index → fetch-back |
| `scripts/feed-verify.sh` | standalone too | re-fetches the live index and hash-checks every package it lists |
| `tests/feed-https-server.py` | the HTTPS gate | serves a tree over TLS with the production cache headers (`no-cache` on indexes, `immutable` on packages/keys), no directory listings |
| `tests/feed-https-publish-test.sh` | the HTTPS gate | publish → live fetch-back → corrupt-package negative → restore → no-rebuild proof, all over a real HTTPS URL |

## Hand-running a publish

```sh
# one-time tooling (pinned SDK image; no OpenWrt checkout needed)
scripts/get-host-apk-tools.sh --out .feed-tools/apk
export FEED_APK_BIN=$PWD/.feed-tools/apk/bin/apk
export FEED_USIGN=$PWD/.feed-tools/apk/bin/usign

# one-time per channel
scripts/feed-keygen.sh --out ~/keys/testing --name tollgate-testing          # apk (ec)
scripts/feed-keygen.sh --out ~/keys/testing --name tollgate-testing --type usign

# every release (apk)
scripts/feed-manifest.sh build-out --out build.sha256
scripts/feed-publish.sh --artifacts build-out --manifest build.sha256 \
  --tree /srv/feed-tree --channel testing --line 25.12 --arch aarch64_cortex-a53 \
  --sign-key ~/keys/testing/tollgate-testing.sec --keys-dir ~/keys/testing/pub \
  --publish-target feed@vps2:/srv/www/feed --base-url https://feed.example \
  --record records/testing-25.12-aarch64_cortex-a53.json

# every release (opkg — see the 24.10 note below)
scripts/feed-publish.sh --format opkg --artifacts build-out-ipk --manifest build-ipk.sha256 \
  --tree /srv/feed-tree --channel testing --line 24.10 --arch aarch64_cortex-a53 \
  --ipkg-index ~/openwrt-sdk-24.10/scripts/ipkg-make-index.sh \
  --sign-key ~/keys/testing-opkg/tollgate-testing.sec --keys-dir ~/keys/testing-opkg/pub \
  --base-url https://feed.example
```

Nothing here needs the feed repo's CI: the tree is a durable artifact (commit it
or keep it on a second host) and the publish step is one command, so a dead CI
box cannot orphan a release.

## What the publish step guarantees

1. **No hidden rebuild.** Every manifest entry must exist and hash to the value
   the build job recorded. A mismatch aborts before anything is written.
2. **Immutable, versioned package names.** `<pkg>-<ver>.apk` /
   `<pkg>_<ver>_<arch>.ipk`; a filename without a version is refused.
3. **No silent re-cut.** Republishing *different* bytes under an existing name is
   refused with the fix in the message: bump `PKG_RELEASE` (`-r2`), because
   `apk upgrade` cannot see a same-version re-cut.
4. **Retention.** `--keep N` (default 2) keeps the current and N-1 older versions
   so `--force-downgrade` has something to land on; pruning happens *before* the
   index is generated, so the index never lists a file that was just deleted.
5. **Signing.** An apk index with no signature block, or one whose signature does
   not verify against the key being published, **cannot leave the script**. For
   opkg the list is signed with usign and verified locally the same way.
6. **Atomic index swap.** The index is written next to its final name and moved
   with `mv` — same directory, same filesystem. A reader sees the old index or
   the new one, never a partial file.
7. **Packages before index.** The rsync publish copies packages first, then the
   index (`--delay-updates` renames each file only once it is fully transferred).
8. **Fetch-back assertion.** With `--base-url`, the live index is re-fetched with
   `Cache-Control: no-cache` and every package it lists is downloaded and
   hash-compared. Non-zero exit on any mismatch, missing package, or when a
   manifest file is absent from the index (which is also the staleness test).
9. **Bounded runtime.** Phase timings are printed and the run fails if it exceeds
   `--max-seconds` (default 300) — a hidden recompile shows up as a long phase.

## Measured facts (2026-09-13)

Everything below was run, not read. Where a result contradicts the consultant
memo at `~/tollgate-runtime-feed-memo.md`, the memo is corrected here.

| # | Finding | How it was measured |
|---|---|---|
| 1 | The OpenWrt **25.12 target rootfs apk has no `mkndx`** — its command list is add/del/fix/update/upgrade/cache/query/list/dot/policy/search/info/fetch/manifest/extract/verify/audit/stats/version/adbdump. Index building exists only in the SDK's **host** apk-tools (`staging_dir/host/bin/apk`). | `apk mkndx --help` on `openwrt/rootfs:x86_64-25.12.5` vs the SDK's host binary |
| 2 | The memo's `apk mkndx --sign` spelling **fails** (`unrecognized option 'sign'`); the option is `--sign-key`. | host apk-tools 3.0.5 |
| 3 | `apk mkndx --help` **exits 1**, so probing for mkndx must match on text, not exit status. | same |
| 4 | apk-tools 3.0.5 **silently ignores a RELATIVE `--keys-dir`** and then reports `UNTRUSTED signature`. Both `feed-publish.sh` and `feed-verify.sh` therefore always pass absolute paths. | signed index + `--keys-dir .` → UNTRUSTED; `--keys-dir "$PWD"` → `OK` |
| 5 | Signing works exactly as the memo says otherwise: unsigned index → `apk update` exit 1 with `UNTRUSTED signature`; signed index + key installed → exit 0; key missing or the wrong key installed → exit 1. 5/5 cases on real 25.12.5 apk-tools. | `tests/apk-index-trust-test.sh` |
| 6 | The index is **not byte-reproducible**: ECDSA signatures are randomized, so two publishes of identical inputs give different `packages.adb` sha256. Reproducibility is a property of the *package* bytes; the index is validated by signature + listing equality. | two consecutive publishes, sha256 compared |
| 7 | `@tag` repository pinning **is supported on 25.12**: `@tg <index-url>` in the repositories file, then `apk add pkg@tg` installs from that repo and `apk policy` shows the tag. (The memo listed this as unverified.) | real 25.12.5 rootfs |
| 8 | **The memo is wrong about unsigned opkg feeds.** It says 24.10/23.05 ship `/etc/opkg.conf` with no `check_signature` "verified in source". The source tree is indeed clean, but release images are built with `CONFIG_SIGNATURE_CHECK` and `package/system/opkg/Makefile` then appends `option check_signature` to `/etc/opkg.conf`. On a real 24.10.8 rootfs the option is present, and a **bare** option enables the check: `opkg update` fails with `Signature file download failed` and exits 1. With a usign-signed `Packages.sig` + `opkg-key add`, update/install/run/remove all exit 0. | `tests/opkg-index-test.sh` (3/3) + the image's own `/etc/opkg.conf` |
| 9 | `ipkg-make-index.sh` hashes through `$MKHASH <alg> <file>`. OpenWrt's `mkhash` prints only the digest; plain `sha256sum` prints `<hash>  <file>` and the second field's `/` breaks the script's `sed`. `feed-publish.sh` supplies a one-line `mkhash` shim. | failure reproduced, then fixed |
| 10 | A **bare `option check_signature`** behaves exactly like `option check_signature 1`. | both forms tested in the container |
| 11 | The publish→serve→fetch-back loop works over real **HTTPS** with the production cache headers: the index is served `no-cache, no-store, must-revalidate`, packages and keys `public, max-age=31536000, immutable`; the live fetch-back matched the build manifest on the real 7 657 333-byte package; flipping **one byte** in the served package made `feed-verify.sh` exit 1; restoring it made the assertion pass again. | `tests/feed-https-publish-test.sh` (7/7) against `tests/feed-https-server.py` |
| 12 | Publishing touches **no artifact and no compiler**: the sha256-of-sha256s of the artifact directory is identical before and after, the log states no build system was invoked, and the phase table totals 0.6–2.9 s across runs — bounded by `--max-seconds` (default 300), so a hidden recompile cannot pass silently. | same run (`NO-REBUILD PROOF` + phase table) |
| 13 | `feed-keygen.sh` writes the public key to `<out>/pub/<name>.pem`, which is exactly the "public keys only" directory `--keys-dir` demands; pointing `--keys-dir` at the keypair's own directory is refused (it contains a `.sec`). | refusal rule 7 in `tests/feed-publish-test.sh` + the HTTPS gate |
| 14 | The published index's own `arch:` field is asserted against `--arch` at publish time. Nothing else in the pipeline notices a mismatch — the package builds, the index signs, the fetch-back matches — and the router then reports "package not found". | new `arch-check` phase in `scripts/feed-publish.sh`; `--arch` cross-checked from the live index in the HTTPS gate |

Still **not** verified anywhere: installing the real `tollgate-wrt` package on
router hardware, a real 24.10 artifact (none exists, so **no opkg index is
published at all for 24.10** — an empty index reads as a broken feed), and
cross-arch installs. Those belong to FEED-SERVE-PROVE / RC-ACCEPTANCE.

## Cache headers (Caddy)

`deploy/caddy-feed.Caddyfile.example` carries the rule the memo calls the one
lethal failure mode: `no-cache` on every index path, `immutable` on packages.
`feed-verify.sh --headers require` fails a publish whose index is served with
cacheable headers; the default (`warn`) reports it without blocking.

## Router-side wiring

apk (25.12+) — a **full URL to the index file**, plus the key:

```sh
curl -fsSL https://feed.example/keys/tollgate-testing.pem -o /etc/apk/keys/tollgate-testing.pem
echo "https://feed.example/testing/25.12/aarch64_cortex-a53/packages.adb" >> /etc/apk/repositories.d/tollgate-testing.list
apk update && apk add tollgate-wrt
# prod and testing side by side, pinned (verified supported):
#   @tollgate  https://feed.example/prod/25.12/<arch>/packages.adb
#   @testing   https://feed.example/testing/25.12/<arch>/packages.adb
```

opkg (24.10/23.05) — a **directory URL** (`opkg` appends `Packages.gz`), plus the
usign key:

```sh
curl -fsSL https://feed.example/keys/tollgate-testing.pub -o /tmp/tollgate-testing.pub
opkg-key add /tmp/tollgate-testing.pub
echo "src/gz tollgate-testing https://feed.example/testing/24.10/<arch>" >> /etc/opkg/customfeeds.conf
opkg update && opkg install tollgate-wrt
```

Rollback: `apk add --force-downgrade tollgate-wrt=<older-version>` /
`opkg --force-downgrade install tollgate-wrt=<older-version>` — the retained
N-1 versions are what makes that possible.

Never tell a tester to use `--allow-untrusted`. If a publish needs it, the key
installation step is broken.

## Tests

```sh
tests/feed-publish-test.sh --apk-bin .feed-tools/apk/bin/apk     # 12 refusal rules, no docker
tests/apk-index-trust-test.sh --apk-bin .feed-tools/apk/bin/apk  # 5 trust cases, docker + 25.12 rootfs
tests/feed-https-publish-test.sh --artifacts <dir of built .apk> \
  --apk-bin .feed-tools/apk/bin/apk --arch aarch64_cortex-a53   # 7 HTTPS cases, no docker
tests/opkg-index-test.sh --ipkg-index <sdk>/scripts/ipkg-make-index.sh \
  --usign .feed-tools/apk/bin/usign                              # 3 opkg cases, docker + 24.10 rootfs
```

`feed-publish-test.sh`, `apk-index-trust-test.sh` and
`feed-https-publish-test.sh` are wired into `.github/workflows/validate-feed.yml`;
the opkg test needs an SDK for `ipkg-make-index.sh`, so it runs locally/on a
build host.

The HTTPS test needs no Caddy and no VPS: `tests/feed-https-server.py` generates
its own CA, serves one directory on loopback with the same header rules as
`deploy/caddy-feed.Caddyfile.example`, and is what the fetch-back assertion
talks to. It is a rehearsal, not the production server.

## Durability

`records/` holds what survives a dead CI box: the per-channel publish record
(index sha256, key id, per-package sha256/bytes) **and** a committed snapshot of
the generated tree (public key + signed index) with the build manifest, plus the
one-command restore path. See `records/README.md` — including the gap it states
plainly: package *payloads* are not yet mirrored to a second host.
