# t_5c74c02c — Pin release SDK images and fix golang feeds line in validate-feed.yml

## Status
- [x] Recon: card premise + predecessor commit `ebbb18836` found.
- [x] Live Docker Hub verification: newest release tag, all 3 targets == `v25.12.5` (no v25.12.6+ exists).
- [x] Digests confirmed twice (docker manifest inspect --verbose + registry docker-content-digest header).
- [x] Image-internal probe (docker run) — authoritative, not inferred.
- [x] golang version resolved at the *exact pinned feed commit*.
- [ ] Gap A: image ref unpinned-by-digest (`openwrt/sdk:${{ matrix.target }}-v25.12.5`).
- [ ] Gap B: matrix-driven golang version (card requires matrix include var).

## Verified pin table (all live-checked at edit time, 2026-10-12)

| target | pinned image tag | manifest digest (sha256) |
|---|---|---|
| x86-64 | `openwrt/sdk:x86-64-v25.12.5` | `e916b7cc555890bdc4725c926e139b888294f0c8f56561b88d8da3a6348616a2` |
| mediatek-filogic | `openwrt/sdk:mediatek-filogic-v25.12.5` | `011c367ac3e63ab3fd345bdb242564fedda033b40e73f883bd550fcf0d27bf9c` |
| ramips-mt7621 | `openwrt/sdk:ramips-mt7621-v25.12.5` | `45a090c9883f42b649be77a1610a5bae4aae6c914e7ea4a5396be47707b74701` |

| target | OpenWrt branch | required golang pkg |
|---|---|---|
| x86-64 / mediatek-filogic / ramips-mt7621 | 25.12 (all three) | `golang1.26` |

## Evidence chain for "all three targets are branch 25.12" (this is the load-bearing claim)
`docker run openwrt/sdk:x86-64-v25.12.5 cat /builder/feeds.conf.default` gives:
    src-git --root=package base https://git.openwrt.org/openwrt/openwrt.git^f0a60eee2fe051741c643ea6118718aae1ef17fb
    src-git packages ...^5caa62e0bc9f7fb9b0c12a23267bceb7724214dd
Commits API on `f0a60eee2fe051741c643ea6118718aae1ef17fb`:
    message = "OpenWrt v25.12.5: adjust config defaults"  (date 2026-06-29)
    compare f0a60eee...openwrt-25.12 -> status=ahead, ahead_by=252, behind_by=0
  => the image's base commit is v25.12.5 and is an ancestor of branch openwrt-25.12.
`openwrt/packages` @ the image's pinned feed commit `5caa62e0`:
    lang/golang contains golang + golang1.26 (NO golang1.27 yet)
    golang-values.mk:127  GO_DEFAULT_VERSION:=1.26
  => golang1.26 is the correct feeds-install target for this image.

Note: edge `openwrt/packages` (25.12 tip) has since added golang1.27, but the image
pins its own feed commit, so 1.26 is correct *for the pinned image*.

## KEY FINDING — the card premise is partially stale (recorded, not hidden)
Card says "*currently uses MOVING openwrt/sdk:*-master images*" and
"*line ~178 'feeds install golang<X>'*". Both are ALREADY FIXED on `origin/main`:
1. `:*-master` -> `v25.12.5` in commit `ebbb18836`, in `origin/main`.
2. golang line is already `./scripts/feeds install golang golang1.26 jq`
   (origin/main:185) and `golang1.26` **is** correct for 25.12 (`GO_DEFAULT_VERSION:=1.26`).
So the only genuinely-unmet acceptance criterion on origin/main is the DIGEST pin
(acceptance requires `<tag>@sha256:<digest>`; origin/main has a bare tag).

## Pre-change RED evidence (card's 'failing test' artifact for a pure-YAML change)
run 38157313203 @ head 39a4d3574 (felixfelix-bot/feed, pull_request): 5 of 7 jobs failed
    SDK build (x86-64|mediatek-filogic|ramips-mt7621)  STEP 12 "Version check inside the built package"
        -> "FAIL: service binary not found in build_dir"
    Runtime feed index (publish, sign, trust)  -> "feed-publish refusal rules: FAIL — 20 failure(s), 1 passed"
    Version identity, hash & files             -> "FAIL  files/ differs from the pinned tag's packaging/files/"
raw: .evidence/t_5c74c02c-pre-change-red.log

## Files touched
- .github/workflows/validate-feed.yml (pending)
