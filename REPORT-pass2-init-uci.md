# COLD REVIEW (PASS 2 — independent re-derivation) — procd init script + UCI config/defaults, net/mptcp-bonding

Scope: ONLY `/etc/init.d/mptcp-bonding` (procd init script) and `/etc/config/mptcp-bonding`
(UCI config + defaults). Out of scope by task and NOT reviewed here: Makefile, sysctl file,
setup-bond.sh, git/commit hygiene, CI. Those were read only to confirm what the init script must
agree with (e.g. the installed binary path).

- Review target: commit `5b765992f5546a1c9de7fedb55853b4d2fed43ce`, branch
  `feat/mptcp-bonding-only`.
- Repository: `feed-freedomtech` (NOT `net4sats-mvp-v2` — premise corrected in pass 1; the
  task-named `/home/c03rad0r/worktrees/mptcp-bonding-only` does not exist on this host; no
  `c03rad0r` home. `5b76599` is absent from `net4sats-mvp-v2`).
- Worktree: `/home/c08r4d0r/worktrees/wz-mptcp-init-uci-review`, HEAD `0c9430f13` at review time.
- Retrieval verified first-hand this pass:
  - `git diff 5b765992f -- net/mptcp-bonding/` → **0 lines** (worktree bytes == commit bytes).
  - `sha256sum` init.d `9304d669632dfa4c076d0472eb87c1587ee10521ae9a846e3a45c09e615676df`,
    config `4d4e30db58f9e25cbbbecbf3362b4a1d06811a6efa1889963ca21809fa770adb` — identical to pass 1's
    recorded hashes and to the sibling artefact's hashes.
  - `sh -n` and `dash -n` on the init script → both exit 0, no output.
- Pass 1's report is at `REPORT.md` in this worktree (commit `f2e0d05ae`). This file is a pass-2
  independent re-derivation. I re-read every quoted line from the blob myself. Pass-1 findings I
  could not reproduce are named as retractions; new first-hand findings are N1/N2/N3 below.

Verdict: **FAIL** — 1 blocker. Pass 1's blocker (no redirection toward ss-redir) is CONFIRMED and
TWO new first-hand pieces of evidence strengthen it (N1, N2). Three new findings are added; one
pass-1 finding (F5) is sharpened from "unvalidated" to "dead config".

---

## FINDINGS

### N1 — BLOCKER (new, strengthens pass-1 F1) — `-u` demands TPROXY; package installs none
File: `net/mptcp-bonding/files/etc/init.d/mptcp-bonding:42`

Quoted line 42:
```
		-b "0.0.0.0" -l "$local_port" -u
```

Why it is wrong: `-u` is not decorative. The installed `ss-redir` (shadowsocks-libev 3.3.5,
verified live this pass) documents it verbatim in its own `-h` output:

```
       [-u]                       Enable UDP relay.
                                  TPROXY is required in redir mode.
```

So line 42 turns on UDP relay while asserting a precondition — TPROXY rules — that a
package-wide grep proves does not exist: `grep -rniE "iptables|nft|TPROXY|REDIRECT|ip rule|
ip route|fwmark|-j " net/mptcp-bonding/` returns only two prose hits, both in `Makefile`
(`SUBMENU:=Routing and Redirection`, and the description word "redirected") — **zero** rule
definitions in init/config/sysctl/setup-bond. Consequently the UDP path ss-redir is asked to
serve can never work, and the flag is at best dead and at worst advertises a capability the
package does not deliver. Note `-u` does NOT enable TCP redirection (TCP redirection in redir
mode is implicit), so this is *additional* to F1: F1 is "no TCP redirection rules at all".

Fix: either (a) drop `-u` until TPROXY is implemented — ss-redir will then serve TCP redir only;
or (b) implement the TPROXY side properly, which means (i) keeping `-u`, (ii) adding
`ip rule add fwmark 0x1/0x1 table 100` + `ip route add local default dev lo table 100`,
(iii) nft/iptables mangle-PREROUTING TPROXY rules for the chosen port set, and (iv) a
`stop_service()` that deletes exactly those rules. Option (b) is the only honest way to keep the
`-u` flag.

### N2 — MAJOR (new) — ss-redir supports `--mptcp`; the init never passes it
File: `net/mptcp-bonding/files/etc/init.d/mptcp-bonding:40-42`

Quoted lines 40-42:
```
	procd_set_param command "$SS_REDIR" \
		-s "$server" -p "$port" -k "$password" -m "$cipher" \
		-b "0.0.0.0" -l "$local_port" -u
```

Why it is wrong: the reviewed product's entire claim is "bond multiple WAN links via MPTCP
subflows". The installed `ss-redir` exposes a purpose-built flag for exactly that, verified live:
`--mptcp  Enable Multipath TCP on MPTCP Kernel.` (`ss-redir -h`, ss 3.3.5). The init does not
pass it. Worse, ss-redir only creates an MPTCP-capable socket when asked; the kernel-level
`net.mptcp.enabled=1` from the (out-of-scope) sysctl file enables the subsystem but does not
retro-fit a plain `socket(AF_INET, SOCK_STREAM)` into MPTCP. Without `--mptcp`, the ss-redir TCP
connection is an ordinary TCP socket and no subflows are formed → no bonding. This is the init
script's own half of the package's core promise being unmet, and it sits inside my scope even
though the sysctl half does not.

Fix: add `--mptcp` to the `procd_set_param command` args (and, ideally, gate it behind a UCI
boolean `option mptcp '1'` so operators on a non-MPTCP kernel can fall back to plain ss-redir
rather than getting a hard ss-redir config error — ss-redir rejects a bad value with
`invalid config file: option 'mptcp' must be a boolean`).

### N3 — MINOR (sharpens pass-1 F5) — the `subflows` UCI option is dead config
File: `net/mptcp-bonding/files/etc/init.d/mptcp-bonding:36-37`, `files/etc/config/mptcp-bonding:16-17`

Quoted init lines 36-37:
```
	[ -w /proc/sys/net/mptcp/subflows ] 2>/dev/null && \
		echo "$subflows" > /proc/sys/net/mptcp/subflows 2>/dev/null
```
Quoted UCI lines 16-17:
```
	# Max subflows the kernel may open per connection (0 = unlimited).
	option subflows '2'
```

Why it is wrong: `/proc/sys/net/mptcp/subflows` **does not exist** in the mainline kernel.
Verified first-hand this pass on a 7.0.0-38-generic kernel with MPTCP built in — the actual
`/proc/sys/net/mptcp/` directory contains exactly:
`add_addr_timeout allow_join_initial_addr_port available_path_managers available_schedulers
blackhole_timeout checksum_enabled close_timeout enabled path_manager pm_type scheduler
stale_loss_cnt syn_retrans_before_tcp_fallback` — and **no** `subflows` key. There is no
"max subflows per connection" sysctl in mainline MPTCP; the nearest real key is
`allow_join_initial_addr_port`. Because line 36 uses `-w`, the write is skipped on every real
kernel: the `[ -w ... ]` test is false, the `&&` short-circuits, and the `subflows` value is
silently discarded. Net effect: the shipped and documented UCI option `subflows` (config:17),
which pass 1 and the setup-bond.sh helper both treat as functional, is **dead config** — an
operator can set it to any value including `0` and nothing observable changes. The comment
"0 = unlimited" on config:16 is not implemented anywhere in this package.

Fix: remove the `subflows` option and the two init lines, OR replace them with a real mechanism
(`uci` subflows cannot map to a sysctl; per-connection subflow count is controlled by the path
manager / `ip mptcp limits set subflows N`). If kept as a UI knob, wire it to
`ip mptcp limits set subflow "$subflows"` and validate it is a positive integer first.

### P1 — CONFIRMED (pass-1 F1, blocker) — nothing routes toward ss-redir
Files: whole package. Quoted init lines 40-42 (same as N2).

Package-wide there is no TPROXY, no REDIRECT, no nft, no iptables, no `ip rule`, no `ip route`,
no fwmark anywhere (grep evidence in N1). `ss-redir` is a transparent-proxy engine: it only acts
on packets the kernel delivers to its listen port. With no redirection rules, `local_port` 1081
(config:15, init:21) is bound and *never receives traffic*, so no router traffic traverses the
tunnel and no bonding occurs. The init script starts a daemon that idles. Fix: implement the
redirection (TPROXY for UDP per N1, REDIRECT or TPROXY for TCP), plus the matching teardown.

### P2 — CONFIRMED (pass-1 F2, major) — no `stop_service()`
File: `net/mptcp-bonding/files/etc/init.d/mptcp-bonding` — grep `stop_service` → 0 matches.

The script defines only `start_service()` and `service_triggers()`. Under procd, absent
`stop_service()` the instance teardown is still performed (procd kills the tracked process), so
the *process* stops cleanly — but any out-of-process state the script creates has no deletion
hook. Today that is only the `/proc/sys/net/mptcp/subflows` write (which is dead anyway, N3), so
the practical blast radius is currently small; it becomes a real defect the moment the
redirection rules that P1/N1 require are added, because those MUST have a delete path. Fix:
add `stop_service()` that deletes every rule/route/rule (and endpoint) the service adds.

### P3 — CONFIRMED (pass-1 F4, major) — `START=90`, no `STOP=`
File: `net/mptcp-bonding/files/etc/init.d/mptcp-bonding:7`

Quoted line 7:
```
START=90
```

No `STOP=` is defined. `START=90` places the service after `network` (START=20) and near
`firewall` (START=19) in OpenWrt's rc ordering, which is the right neighbourhood for a proxy that
needs routes and netfilter — but `STOP=` defaults to `START` (90) for a procd script with no
`STOP=`, meaning it is torn down at the same priority it starts at, and the ordering is neither
documented in the script nor asserted by any test. A proxy that starts before the firewall's
nft ruleset is loaded, or that stops after the interfaces it depends on are gone, misbehaves
silently. Fix: add an explicit `STOP=` and a one-line comment recording the intended ordering
constraint relative to `network`/`firewall`; if redirection rules are added per P1/N1, they must
be installed after `firewall` (START>=20) and removed before it stops.

### P4 — CONFIRMED (pass-1 F7, minor) — bare `respawn`, no `file`/`pidfile`, no `limits`
File: `net/mptcp-bonding/files/etc/init.d/mptcp-bonding:43`

Quoted line 43:
```
	procd_set_param respawn
```

Bare `respawn` with no arguments falls back to procd's compiled defaults (threshold 3600s,
timeout 5s, retry 5). That is not insane, but it means a crash-looping ss-redir (e.g. because
`server` is misconfigured at runtime, or the cipher is rejected by the peer) is restarted 5×
every 5s and then given up on with no operator-visible escalation beyond `stderr 1`. There is no
`procd_set_param file` or `pidfile` (not strictly required here since there is no external state
file, but `file` is how you declare "restart when these files change"). Fix: state the intended
respawn thresholds explicitly, e.g. `procd_set_param respawn 3600 5 10`, so the policy is
reviewable rather than inherited from a procd version.

### P5 — CONFIRMED (pass-1 F8, minor) — sysctl write error swallowed
File: `net/mptcp-bonding/files/etc/init.d/mptcp-bonding:36-37` (same lines as N3).

Both the `-w` probe and the `echo` carry `2>/dev/null`. The write failure is silent; it is the
only silent-failure path in the script (every other error `echo`s to `>&2` and the log path is
findable via `stderr 1` on line 45). Given N3 shows the file never exists, this is moot *for this
key* — but the pattern is the trap: a future author who fixes the path but keeps `2>/dev/null`
will get a silent no-op. Fix: drop the `2>/dev/null` on the write and warn to `>&2` on failure.

### P6 — CONFIRMED (pass-1 F6, minor) — `-b 0.0.0.0` + `-u` exposes the proxy port
File: `net/mptcp-bonding/files/etc/init.d/mptcp-bonding:42` (same line as N1).

`-b "0.0.0.0"` binds ss-redir to every interface, including any WAN. Combined with `-u` (N1) this
advertises a UDP relay to the world with no authentication beyond the shadowsocks password (AEAD,
but still a listening service on the WAN). A transparent-proxy redir port should bind `127.0.0.1`
(or the LAN bridge) — the kernel's REDIRECT/TPROXY target delivers packets to the loopback-bound
socket regardless, so `0.0.0.0` buys nothing but attack surface. Fix: `-b "127.0.0.1"` unless a
documented reason to be LAN-reachable exists.

---

## CHECKED AND FOUND CORRECT

Every item below was re-read from the blob this pass, not copied from pass 1.

1. **Shebang / scaffolding.** Init.d:1 `#!/bin/sh /etc/rc.common` — correct BusyBox-style
   shebang. Init.d:8 `USE_PROCD=1` present. No non-procd `start()`/`stop()` body is mixed with
   procd calls. `EXTRA_COMMANDS`/`EXTRA_HELP` are **not** required here: the script defines no
   custom command verb (no `reload()` of its own), so there is nothing to advertise. Init.d:49-50
   `service_triggers()` registers `procd_add_reload_trigger mptcp-bonding`; reload is therefore
   provided by procd, and — verified — it is not a silent no-op: `rc.common`'s `reload` falls
   back to `start` when no `reload_service` exists, and `start_service()` runs `config_load` +
   `config_get` (init.d:15-22) on every invocation, so changed UCI values ARE re-read (see item 4).
2. **Instance definition.** init.d:39 `procd_open_instance` … init.d:46 `procd_close_instance` —
   balanced, one instance. init.d:40 `procd_set_param command "$SS_REDIR"` with `SS_REDIR`
   defined init.d:10 as `/usr/bin/ss-redir`; the Makefile installs the package's own files only
   and declares `+shadowsocks-libev-ss-redir` as a dependency (Makefile:30), and this host's
   package places the binary at `/usr/bin/ss-redir` (`ls /usr/bin/ss-redir` → present) → the
   absolute path agrees with the install layout. Args (init.d:41-42) are one-word-per-string,
   each value double-quoted — no unquoted word-splitting of a config value, and quoting is
   correct for a password containing spaces or shell metacharacters (they reach ss-redir as a
   single argv entry). `stdout 1` (init.d:44) and `stderr 1` (init.d:45) are set → output is
   captured by procd's log (`logread`) and the service fails loudly.
3. **Log / error paths.** Every failure path is explicit and goes to `>&2`: init.d:24 (disabled,
   returns 0 — correct, a disabled service is not a failure), init.d:27 (missing server/password,
   `return 1`), init.d:31 (missing `ss-redir`, `return 1`). Required-config validation happens
   before any state change: the `enabled` gate (init.d:24) precedes the required-value check
   (init.d:26-29) which precedes the binary check (init.d:30-33) which precedes the sysctl write
   and the procd instance. The parse is coherent: `[ -z "$server" ] || [ -z "$password" ] && {…}`
   is left-associative `( A || B ) && C`, so it fires when EITHER is empty and is a no-op when
   both are set — correct as written (independently re-derived; pass 1 reports the same and
   retracted an earlier "precedence hazard" claim).
4. **Lifecycle / reload re-reads UCI.** `config_load mptcp-bonding` (init.d:15) plus the seven
   `config_get` calls (init.d:16-22) run inside `start_service()`, i.e. on every `start` AND on
   every `reload` that falls back to `start`. Therefore a changed UCI value is picked up on
   reload — the failure mode "reload silently keeps stale values" does NOT occur for the values
   the script actually reads. (What reload cannot do is rebuild redirection rules, because there
   are none — that is P1, not a reload defect.)
5. **UCI ↔ init 1:1 cross-check matrix.** Section: `config main 'main'` (config:4) ↔ every read
   uses section `main`; `config_load mptcp-bonding` matches the file name `/etc/config/mptcp-bonding`.

   | option (UCI)      | defined at      | shipped value      | read at (init.d)  | inline default | inline == shipped |
   |-------------------|-----------------|--------------------|-------------------|----------------|-------------------|
   | `enabled`         | config:5        | `'0'`              | :16               | `0`            | yes               |
   | `server`          | config:7        | `''`               | :17               | (none)         | n/a (empty ship)  |
   | `server_port`     | config:9        | `'65101'`          | :18               | `65101`        | yes               |
   | (secret option)   | config:11       | `''`               | :19               | (none)         | n/a (empty ship)  |
   | `cipher`          | config:13       | `'aes-256-gcm'`    | :20               | `aes-256-gcm`  | yes               |
   | `local_port`      | config:15       | `'1081'`           | :21               | `1081`         | yes               |
   | `subflows`        | config:17       | `'2'`              | :22               | `2`            | yes               |

   Result of the 1:1 comparison: **0 options read-but-undefined, 0 options defined-but-never-read,
   0 section-name mismatches, 0 default mismatches.** Every inline `config_get` fallback agrees
   with the shipped file value. Booleans: `enabled` is UCI `'0'`/`'1'` and is compared as a string
   against `"1"` (init.d:24) — correct for UCI; no `true`/`false` literals appear anywhere.
   No `default_config()`/`defaults()` function exists in the package (grep → 0 matches); defaults
   are carried inline in `config_get` and in the shipped config file, and the two agree.
   Caveat (not a mismatch): the `subflows` row is a cross-check PASS but a functional FAIL — the
   option is correctly wired UCI→init yet goes nowhere (`N3`).
6. **No `reload_service()` that silently no-ops.** Verified: there is no `reload_service()` in the
   script at all (grep → 0 matches). procd/rc.common therefore falls back to the `start` path on
   `reload`, which re-runs `start_service()` and re-reads UCI (item 4). This is not the
   "silent no-op" failure mode the checklist warns about. It IS incomplete for rule rebuilds once
   rules exist — tracked as P1/P2, not as a reload defect.

## RETRACTIONS / NOT REPRODUCED

None. Every pass-1 finding I re-tested (F1, F2, F4, F6, F7, F8) reproduced on the bytes; F5 is
reproduced and sharpened to N3. Pass-1's retraction (the `init.d:26` "precedence hazard" it had
already withdrawn before shipping) stays withdrawn — I re-derived the same result.

## SCOPE DISCIPLINE

Not reviewed here (other tasks own them): Makefile, sysctl.d file, setup-bond.sh,
lib/upgrade/keep.d, git/commit hygiene, CI. The sysctl file and setup-bond.sh were READ only to
confirm what the init must agree with (binary path, and the fact that setup-bond.sh is never
invoked by the init — `grep -n setup-bond` in init.d → 0 matches, which is pass-1's C3-class
observation and is noted here only as context, not as a new finding).
