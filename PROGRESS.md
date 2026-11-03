# PROGRESS — pin release SDK images + per-branch golang in validate-feed.yml

Card t_5c74c02c · repo `FreedomTechFeed/feed` · clone `~/worktrees/feed`
(created fresh from https://github.com/FreedomTechFeed/feed — no `feed`
checkout existed on this host; `~/worktrees` is a symlink to `/data/worktrees`).

Branch: `ci/pin-sdk-images-and-golang` (off `origin/main` @ `24fb821`).

## Findings -> status

| # | Finding | Status |
|---|---|---|
| 1 | No `feed` checkout, no `gh` on PATH at first, no netrc, `id_fleet` not authorised on github.com. Later found `gh` at `/usr/bin/gh` plus the worker's provisioned `GH_TOKEN` at `/run/user/1000/hermes-openbao/providers.env` (account `felixfelix-bot`). Cloned the public repo. | resolved for reads |
| 2 | **The `-master` pin is already fixed on `origin/main`**: `ebbb188` (2026-08-30) replaced `openwrt/sdk:*-master` with `*-v25.12.5` release tags. Remaining gap vs the card: (a) **no digests** — a floating tag can be re-pushed; (b) the golang install line is **hardcoded** `golang1.26`. | verified |
| 3 | Release tags verified live at registry-1.docker.io (Hub API `digest` == registry `docker-content-digest` == sha256 of the manifest body; `manifest.v2+json`, single-arch, 12 layers): `x86-64-v25.12.5` → `sha256:e916b7cc…8616a2`, `mediatek-filogic-v25.12.5` → `sha256:011c367a…27bf9c`, `ramips-mt7621-v25.12.5` → `sha256:45a090c9…b74701`. Raw: `~/feed-evidence/registry-probe/`. | verified |
| 4 | Per-branch golang from `openwrt/packages`: **openwrt-25.12 → `GO_DEFAULT_VERSION:=1.26`** (`lang/golang/golang-values.mk`; `golang1.26/` variant exists); **openwrt-24.10 → `GO_VERSION_MAJOR_MINOR:=1.23`** (`lang/golang/golang/Makefile`, only an unversioned `golang` dir). All three pinned targets are 25.12 → `golang1.26`, i.e. today's value is already correct — so the fix is *matrix-driving*, not a version bump. | verified |
| 5 | Matrix now carries `tag`/`digest`/`branch`/`golang` per row; `image: openwrt/sdk:${{ matrix.tag }}@${{ matrix.digest }}`; install line `golang${{ matrix.golang }}`. Adding a 24.10 target later needs one matrix row, no script edit. | done |
| 6 | Local gates: `tests/test_workflow_pins.py` (7 tests) RED against HEAD's workflow (6 failed / 1 passed — `~/feed-evidence/red.txt`) and GREEN against the pinned one; `actionlint` 1.7.7 exit 0; repo `scripts/sync-from-upstream.sh` untouched. | verified |
| 7 | `AGENTS.md` could not be edited (protected-agent-instruction guard refused the write in an unattended run). The pin is documented in `README.md` + `PLAN.md` in the same commit. | noted |
| 8 | The card's "capture the latest red `gh run list`" premise no longer holds: latest upstream run is **green** (run 72, schedule, head `24fb821`, 2026-11-02). Failing artifact = TDD red run against HEAD's workflow. Note the earlier lane's finding stands: `GH_TOKEN` is read-only on `FreedomTechFeed/feed` (`push:false`) and Actions is inert on the fork (`422`) — see `~/feed-evidence/PROGRESS-prior-validate-feed-dispatch.md`. | noted |

## Status
- [x] locate repo / clone worktree
- [x] verify release tags + digests live
- [x] determine per-branch golang
- [x] matrix-drive tag + digest + branch + golang
- [x] guard tests (red → green), actionlint
- [x] docs same commit (README, PLAN)
- [ ] commit
- [ ] push

## Files touched
- `.github/workflows/validate-feed.yml` — matrix carries `tag`/`digest`/`branch`/`golang`;
  digest-pinned `image:`; `feeds install … golang${{ matrix.golang }} …`; pin-date/why comments.
- `tests/test_workflow_pins.py` — new guard tests (pytest).
- `README.md`, `PLAN.md` — SDK pin + per-branch golang docs.
- `.gitignore` — ignore `__pycache__/`, `.pytest_cache/`.
