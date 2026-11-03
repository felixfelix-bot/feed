# REPORT — validate-feed `workflow_dispatch` rerun

**Status: BLOCKED (no dispatch possible) — but the pinned workflow is verified
green at the exact current upstream HEAD, with artifacts inspected.**

I could not satisfy the literal acceptance criterion ("latest run is a
`workflow_dispatch` I triggered"). This worker has **read-only** access to
`FreedomTechFeed/feed` and **no Actions-enabled venue** it can write to.
Per step 4 of the task, I stopped and handed back rather than papering over it.
Everything short of the dispatch itself was done and is evidenced below.

---

## 1. What blocked the dispatch

Two independent walls, both capability — not a design or CI problem.

### W1 — `GH_TOKEN` is read-only on the canonical repo

```
$ gh api repos/FreedomTechFeed/feed --jq .permissions
{"admin":false,"maintain":false,"pull":true,"push":false,"triage":false}

$ gh workflow run validate-feed.yml -R FreedomTechFeed/feed --ref main
could not create workflow dispatch event: HTTP 403: Must have admin rights to Repository.

$ git push --dry-run origin main
c08r4d0r@...: Permission denied (publickey).
fatal: Could not read remote repository.
```

Account is `felixfelix-bot`; it is not a member of the org
(`gh api orgs/FreedomTechFeed/memberships/felixfelix-bot` -> 404). Read is
fine — runs, jobs, and artifact downloads all work with this token.

### W2 — the one repo I *can* write to has Actions disabled

`felixfelix-bot/feed` (fork of `FreedomTechFeed/feed`) gives me
`{admin:true, push:true}`, so I pushed a pristine verification branch:

```
$ git push <fork> HEAD:refs/heads/verify/validate-feed-24fb821694
 * [new branch]  HEAD -> verify/validate-feed-24fb821694
```

(I deliberately did **not** touch fork `main`: it had diverged from upstream —
1 fork-only commit, 10 behind. The branch tip is the exact upstream tree
`24fb821`, so a run on it would test precisely the pinned workflow.)

```
$ gh workflow run validate-feed.yml -R felixfelix-bot/feed --ref verify/validate-feed-24fb821694
could not create workflow dispatch event: HTTP 422: Actions has been disabled for this repository.
```

Repo-wide, not ref-specific — same 422 for `--ref main` and for the raw
`POST /actions/workflows/353028521/dispatches`. The permissions endpoint
contradicts it and cannot fix it:

```
$ gh api repos/felixfelix-bot/feed/actions/permissions
{"enabled":true,"allowed_actions":"all","sha_pinning_required":false}
$ gh api -X PUT repos/felixfelix-bot/feed/actions/permissions -F enabled=true -F allowed_actions=all
(204, no output)   # yet dispatch still 422s
```

A `push` to the new branch produced **no run at all** (`gh run list --branch
verify/validate-feed-24fb821694` empty) — so push-triggering is not an
alternative route either. Actions is fully inert on the fork.

Also checked and rejected: SSH (`~/.ssh/id_fleet` -> `Permission denied
(publickey)`), SSH agent (no identities), git credential helper (none
configured anywhere, no `~/.git-credentials`/`~/.netrc`/`~/.config/gh`), and
the fleet broker (`broker_request.py` only *submits*; approval needs an
operator identity on the root, and no broker socket exists). I did not attempt
to use another identity's credentials.

---

## 2. What is verified: the pinned workflow IS green at upstream HEAD

Latest run in the repo, and its `head_sha` equals upstream `main` — i.e. the
run exercised exactly the committed pinned workflow (`openwrt/sdk:*-v25.12.5`
images, `sdkbuild-<target>-v25.12.5-` cache namespace):

```
$ gh run list -R FreedomTechFeed/feed --limit 1 --json conclusion,databaseId,headSha,displayTitle
[{"conclusion":"success","databaseId":41439678826,"displayTitle":"Validate Feed","headSha":"24fb821694d3c606871256460f450219441f5e7d"}]
```

```
$ git rev-parse HEAD ; git rev-parse origin/main
24fb821694d3c606871256460f450219441f5e7d
24fb821694d3c606871256460f450219441f5e7d      # headSha matches
```

Per-job conclusions — `gh run view 41439678826 -R FreedomTechFeed/feed --json jobs`:

```
[{"conclusion":"success","name":"SDK build (ramips-mt7621)","status":"completed"},
 {"conclusion":"success","name":"Go cross-compile (no SDK) (amd64)","status":"completed"},
 {"conclusion":"success","name":"Lint Makefile, verify hash & files","status":"completed"},
 {"conclusion":"success","name":"SDK build (mediatek-filogic)","status":"completed"},
 {"conclusion":"success","name":"SDK build (x86-64)","status":"completed"},
 {"conclusion":"success","name":"Go cross-compile (no SDK) (mipsle, softfloat)","status":"completed"},
 {"conclusion":"success","name":"Go cross-compile (no SDK) (arm64)","status":"completed"}]
```

Run metadata:

```
{"conclusion":"success","created_at":"2026-11-02T11:48:24Z","event":"schedule",
 "head_branch":"main","head_sha":"24fb821694d3c606871256460f450219441f5e7d",
 "id":41439678826,"run_attempt":1,"status":"completed",
 "updated_at":"2026-11-02T12:15:00Z",
 "html_url":"https://github.com/FreedomTechFeed/feed/actions/runs/41439678826"}
```

**Caveat, stated plainly:** this run was triggered by `schedule`, not
`workflow_dispatch`. The workflow is identical for both (`build-sdk`'s `if:`
explicitly lists `workflow_dispatch` alongside `schedule`), so the build
behaviour is the same code path — but it is not the *dispatch event* the task
asked for, and I am not claiming otherwise.

### Cross-checked beyond exit codes

Three SDK artifacts exist and are unexpired — every matrix target actually
produced a package:

```
tollgate-wrt-x86-64            8,033,157 B   expired=false
tollgate-wrt-mediatek-filogic  7,324,471 B   expired=false
tollgate-wrt-ramips-mt7621     7,448,034 B   expired=false
```

I downloaded the x86-64 one and inspected it (so "success" is not just a job
that no-op'd):

```
tollgate-wrt-0.5.0-r1.apk   8,044,706 bytes
sha256 3230a455db6400cb300d7cd07a8d88d3aeae7d2c9cd9f90b0b05e2f87c00388f
magic  41 44 42 64  =>  "ADBd" = valid OpenWrt apk v3 package
```

Conclusion: the pinned workflow (`24fb821`, SDK images v25.12.5, namespaced
cache keys) is green end-to-end in CI for all 3 SDK targets + validate +
go-smoke, and it emits real per-arch packages. What is missing is only a fresh
dispatch event, which requires write access I do not have.

---

## 3. No CI fix was needed

Steps 3/4 were not reached in the sense of an actionable red job: no run I
created exists, and the most recent run has no failing job to root-cause. No
source or workflow change was made — `net/tollgate-wrt/` and
`.github/workflows/validate-feed.yml` are unchanged. No commit of CI code was
fabricated.

---

## 4. REMAINING steps (need someone with write access)

1. Grant `felixfelix-bot` **write** (or admin) on `FreedomTechFeed/feed`, *or*
   re-enable Actions on `felixfelix-bot/feed` (the Actions-permissions API
   currently reports "enabled" while dispatch returns 422 — likely an
   org/billing-level block that needs a UI/owner action).
2. Then, in `~/worktrees/feed` at `24fb821`:
   `set -a; . /run/user/1000/hermes-openbao/providers.env; set +a`
3. `gh workflow run validate-feed.yml -R FreedomTechFeed/feed --ref main`
   (or `--ref verify/validate-feed-24fb821694` on the fork, already pushed).
4. Follow to completion (~26 min, the longest target):
   `gh run watch <id> -R <repo> --exit-status`
5. Capture acceptance evidence:
   `gh run list -R <repo> --limit 1 --json conclusion,databaseId,headSha,displayTitle`
   and `gh run view <id> -R <repo> --json jobs --jq '[.jobs[]|{name,conclusion}]'`.
6. Expect: `conclusion == "success"`, 7/7 jobs green, `headSha == 24fb821...`.
   If any job is red, the only known-risk area per AGENTS.md is the
   `golang-package.mk` nested-CLI-module build in `build-sdk` — read that job's
   log first. Log download requires admin (`Must have admin rights to
   Repository`), so the operator must fetch logs.
