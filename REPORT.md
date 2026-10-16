# COLD REVIEW — procd init script + UCI config/defaults, net/mptcp-bonding

Scope: ONLY `/etc/init.d/mptcp-bonding` (the procd init script) and `/etc/config/mptcp-bonding`
(the UCI config + defaults). Out of scope by task: Makefile, sysctl file, setup-bond.sh, git/commit
hygiene, CI. Those were read only to confirm what the init script must agree with.

- Review target: commit `5b765992f5546a1c9de7fedb55853b4d2fed43ce` ("feat(feed): add mptcp-bonding
  multi-WAN bonding client package"), branch `feat/mptcp-bonding-only`.
- Repository: **`feed-freedomtech`** (remotes: `origin=github.com/felixfelix-bot/feed.git`,
  `ftf-fork=FreedomTechFeed/packages.git`, `upstream-openwrt=openwrt/packages.git`).
  NOTE: this is NOT `net4sats-mvp-v2`; see "PREMISE CORRECTION" below.
- Worktree used: `/home/c08r4d0r/worktrees/wz-mptcp-init-uci-review` (fresh `git worktree add`,
  HEAD = `5b765992f`).
- Worktree bytes == commit bytes: `git diff 5b76599 -- net/mptcp-bonding/` → **0 lines**.
- File hashes (sha256, computed on the reviewed worktree):
  - `files/etc/init.d/mptcp-bonding` = `9304d669632dfa4c076d0472eb87c1587ee10521ae9a846e3a45c09e615676df`
  - `files/etc/config/mptcp-bonding` = `4d4e30db58f9e25cbbbecbf3362b4a1d06811a6efa1889963ca21809fa770adb`
  These two hashes are byte-identical to the hashes recorded in the sibling artefact
  `net4sats-mvp-v2/docs/mptcp-bonding-cross-check-reconciliation-2026-09-25.md`
  (init.d 9304d669…, UCI 4d4e30db…) → independent confirmation that this review covers the same
  immutable artefact others reviewed.
- Line citations below refer to the **committed blob** (the worktree copy is byte-identical).

## PREMISE CORRECTION (retrieval blocker + resolution)

The task said the content lives in `worktree /home/c03rad0r/worktrees/mptcp-bonding-only`, in repo
`net4sats-mvp-v2`. Both halves of that premise are false on this host:

- `/home/c03rad0r/` does not exist here (task body paths with `STATE_DIR=/home/c03rad0r/...` do not
  resolve; this host is the `c08r4d0r`/`c03r4d0r` worker).
- Commit `5b76599` does **not** exist in `net4sats-mvp-v2` (`git cat-file -t 5b76599` →
  `fatal: Not a valid object name`). It exists in `feed-freedomtech` and on
  `origin/feat/mptcp-bonding-only`.

This was **not** treated as a blocker for the review: the commit is present locally, the exact
target files were retrieved, and the hashes match the sibling document's recorded hashes. Had the
artefact been unretrievable I would have reported a blocker instead of guessing.

---

## FIELD-LEVEL QUOTES (verbatim, from the committed blob)

### init.d — full source (51 lines)

```
 1  #!/bin/sh /etc/rc.common
 2  # procd init for the MPTCP bonding client.
 3  # Brings up a shadowsocks ss-redir toward the convergence-point VPS; the kernel
 4  # MPTCP path manager (enabled via /etc/sysctl.d/mptcp-bonding.conf) splits that
 5  # single connection across the router's upstream WAN links as subflows.
 6
 7  START=90
 8  USE_PROCD=1
 9
10  SS_REDIR=/usr/bin/ss-redir
11
12  start_service() {
13  	local enabled server port password cipher local_port subflows
14
15  	config_load mptcp-bonding
16  	config_get enabled    main enabled 0
17  	config_get server     main server
18  	config_get port       main server_port 65101
19  	config_get password   main password
20  	config_get cipher     main cipher aes-256-gcm
21  	config_get local_port main local_port 1081
22  	config_get subflows   main subflows 2
23
24  	[ "$enabled" = "1" ] || { echo "mptcp-bonding: disabled" >&2; return 0; }
25
26  	[ -z "$server" ] || [ -z "$password" ] && {
27  		echo "mptcp-bonding: set main.server and main.password in /etc/config/mptcp-bonding" >&2
28  		return 1
29  	}
30  	[ -x "$SS_REDIR" ] || {
31  		echo "mptcp-bonding: $SS_REDIR missing (install shadowsocks-libev-ss-redir)" >&2
32  		return 1
33  	}
34
35  	# Apply the subflow cap if the host kernel exposes it.
36  	[ -w /proc/sys/net/mptcp/subflows ] 2>/dev/null && \
37  		echo "$subflows" > /proc/sys/net/mptcp/subflows 2>/dev/null
38
39  	procd_open_instance
40  	procd_set_param command "$SS_REDIR" \
41  		-s "$server" -p "$port" -k "$password" -m "$cipher" \
42  		-b "0.0.0.0" -l "$local_port" -u
43  	procd_set_param respawn
44  	procd_set_param stdout 1
45  	procd_set_param stderr 1
46  	procd_close_instance
47  }
48
49  service_triggers() {
50  	procd_add_reload_trigger mptcp-bonding
51  }
```

### UCI config — full source (17 lines)

```
 1  # Convergence-point VPS (deployed by c03rad0r/tg-mptcp-server Ansible).
 2  # Fill these in before `uci set mptcp-bonding.main.enabled=1`.
 3
 4  config main 'main'
 5  	option enabled '0'
 6  	# Public host / IP of the MPTCP bonding server.
 7  	option server ''
 8  	# shadowsocks server port (Ansible default: 65101).
 9  	option server_port '65101'
10  	# shadowsocks password — must match the server's ss-manager config.
11  	option password ''
12  	# shadowsocks cipher — must match the server (default: aes-256-gcm).
13  	option cipher 'aes-256-gcm'
14  	# Local transparent-proxy port ss-redir listens on.
15  	option local_port '1081'
16  	# Max subflows the kernel may open per connection (0 = unlimited).
17  	option subflows '2'
```

### Related facts read only to confirm agreement (not in scope to review)

- `Makefile:59-60` — installs the init script to `/etc/init.d/mptcp-bonding`
  (`$(INSTALL_DIR) $(1)/etc/init.d`, `$(INSTALL_BIN) ./files/etc/init.d/mptcp-bonding …`).
- `Makefile:20,30` — `PKG_BUILD_DEPENDS:=shadowsocks-libev-ss-redir` and
  `DEPENDS:=+shadowsocks-libev-ss-redir +ip-full +kmod-sched`.
- `Makefile:71-72` — installs the helper to `/usr/lib/mptcp-bonding/setup-bond.sh`.
- Package-wide grep for `iptables|nft|TPROXY|REDIRECT|ip rule|ip route|fwmark|-j ` over the entire
  `net/mptcp-bonding/` tree → **ZERO matches** (this underpins finding F1).

---

## FINDINGS

### F1 — BLOCKER — the service routes nothing toward ss-redir (no TPROXY/REDIRECT rules exist anywhere)

File: `net/mptcp-bonding/files/etc/init.d/mptcp-bonding:39-46`
Quoted:
```
	procd_open_instance
	procd_set_param command "$SS_REDIR" \
		-s "$server" -p "$port" -k "$password" -m "$cipher" \
		-b "0.0.0.0" -l "$local_port" -u
	procd_set_param respawn
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
```
Corroborating quote (the script's own stated intent), `init.d:3-5`:
```
# Brings up a shadowsocks ss-redir toward the convergence-point VPS; the kernel
# MPTCP path manager (enabled via /etc/sysctl.d/mptcp-bonding.conf) splits that
# single connection across the router's upstream WAN links as subflows.
```

Why it is wrong: `ss-redir` is a **transparent-proxy** relay. It only becomes part of the data path
if something (netfilter) hands it packets — i.e. `iptables`/`nft` `REDIRECT --to-ports <local_port>`
or `TPROXY --on-port <local_port>` with an `ip rule`/`fwmark`/route-table setup. This init script
starts the `ss-redir` process and stops there. A package-wide grep finds **no `iptables`, `nft`,
`TPROXY`, `REDIRECT`, `ip rule`, `ip route`, or `fwmark`** anywhere in `net/mptcp-bonding/`
(zero matches). The port the UCI comment calls "Local transparent-proxy port ss-redir listens on"
(`config:14-15`) is never pointed at by any rule.

Net effect: `ss-redir` binds `0.0.0.0:1081`, but no traffic is ever redirected to it, so **no
connection is proxied, hence no MPTCP subflows are ever created, hence no bonding occurs**. The
package as shipped is inert with respect to its advertised purpose. This is a functional blocker,
not a style issue.

Concrete fix — pick one and make it real:
1. Add a firewall-rule layer owned by this package and wired into procd lifecycle. Minimal shape:
   - an `nft`/`iptables` rule set (mangle table, custom chain, mark + `ip rule fwmark <mark> table
     <N>` + `ip route add local 0.0.0.0/0 dev lo table <N>`, then `REDIRECT`/`TPROXY --on-port
     "$local_port"`), and
   - call it from `start_service()` after `config_get` and BEFORE `procd_close_instance`, and
   - tear it down in `stop_service()` (see F2 — that function does not exist today).
2. Or, if redirection is intentionally delegated to an external firewall stack (e.g. an
   OpenWrt `firewall` include shipped by the package), then **ship that include** and reference it,
   and change `init.d:3-5` and `config:14-15` to state that redirection is owned elsewhere. As it
   stands the comments assert a data path that does not exist.

Note: the scope guard "correct table+chain, correct ports, correct mark/route table" cannot be
satisfied as written because **there is no rule to audit** — that absence *is* the finding.

---

### F2 — MAJOR — no `stop_service()`, so init/start-side state (the sysctl write) is never undone and there is nothing to hang rule teardown on

File: `net/mptcp-bonding/files/etc/init.d/mptcp-bonding` (whole file)
Quoted — the set of lifecycle hooks the script defines:
```
service_triggers() {
	procd_add_reload_trigger mptcp-bonding
}
```
and (grep over the file) the only definitions present are `start_service` (`:12`) and
`service_triggers` (`:49`). There is **no `stop_service()`** and **no `reload_service()`**.

Why it is wrong: `rc.common` always calls `stop_service "$@"` from `stop()` (see
`rc.common:156-163`). With no `stop_service`, `stop()` performs only `procd_kill` on the instance —
fine for the daemon itself, but any state introduced outside procd is left behind. Today that is the
`/proc/sys/net/mptcp/subflows` write at `init.d:35-37`; once F1 is fixed it will also be the
firewall rules, and "a rule added without a matching delete on stop/reload" is exactly the class of
bug the checklist asks about. The design has no teardown hook at all, so the fix for F1 cannot be
made correct without adding one.

Concrete fix: add
```
stop_service() {
	# delete the redirection rules / flush the custom chain / restore route table
	# (and, if the package owns it, reset the sysctl it changed)
}
```
and make every `add` in `start_service()` have a matching `del` here.

---

### F3 — MAJOR — `reload` re-runs `start_service`, which re-executes `procd_open_instance`; the reload trigger is declared but there is no explicit reload path, and the sysctl "side write" is re-issued on every reload against a second, independent writer

File: `net/mptcp-bonding/files/etc/init.d/mptcp-bonding:49-51` and `:35-37`
Quoted:
```
service_triggers() {
	procd_add_reload_trigger mptcp-bonding
}
```
```
	# Apply the subflow cap if the host kernel exposes it.
	[ -w /proc/sys/net/mptcp/subflows ] 2>/dev/null && \
		echo "$subflows" > /proc/sys/net/mptcp/subflows 2>/dev/null
```

What is correct (stated precisely, because the sibling doc overstates it): with `USE_PROCD=1` and no
`reload_service()`, authoritative `rc.common:165-172` makes `reload()` call `start`():
```
	reload() {
		if eval "type reload_service" 2>/dev/null >/dev/null; then
			procd_lock
			reload_service "$@"
		else
			start
		fi
	}
```
and procd's `start()` (`rc.common:137-142`) calls `rc_procd start_service` which does
`procd_open_service … procd_close_service set`. `set` **replaces** the instance definition, so
changed UCI values ARE picked up. Therefore reload is **not** a silent no-op, and
`config:14-15`/`17` values changed by an operator *will* take effect on `reload`. This part is
CHECKED AND FOUND CORRECT (see matrix).

What is wrong:
1. Reload delivers *config* changes but does **nothing** for the routing state that F1 must add
   (there is no `reload_service` to rebuild rules; a bare `start` will not re-add them idempotently
   unless the start path is made idempotent). Combined with F2, `reload` cannot be correct.
2. The subflow cap is written to `/proc/sys/net/mptcp/subflows` on **every** start/reload
   (`:35-37`). This is a host-global kernel knob, not per-instance, and the sibling scope note
   (§setup-bond.sh) shows `setup-bond.sh:195-196` writes the *same path* independently. Two owners
   of one global sysctl, one of them a config-driven init script, means an operator's
   `setup-bond.sh` value can be silently overwritten (or vice-versa) depending on call order. It is
   also written *before* any validation of `$subflows` (F5).

Concrete fix: define an explicit `reload_service()` that re-reads UCI (via the existing
`config_load mptcp-bonding` + `config_get`s), then tears down and re-adds the redirection state and
restarts the instance — instead of relying on the bare `start` fallback. And decide a single owner
for the global subflow limit; if the package owns it, do it in one place and document it, and guard
it with a numeric check.

---

### F4 — MAJOR — `START=90` with no `STOP=`, and ordering is asserted nowhere; the script depends on the WAN being up but declares no dependency on it

File: `net/mptcp-bonding/files/etc/init.d/mptcp-bonding:7-8`
Quoted:
```
START=90
USE_PROCD=1
```

Why it is wrong:
- `START=90` alone is legal but places this service in the last start tier, *after* `network`
  (`START=20` in stock OpenWrt) — that direction is fine for "needs WAN up". However it also lands
  **after** the stock `firewall` (`START=19`/`20` band) and after most consumers, i.e. **later than
  the firewall that would need to hold the redirect rules from F1**. If F1 is fixed by adding
  firewall rules, `START=90` means those rules are installed *after* the firewall loads (acceptable
  if the rules live in their own `nft`/`iptables` chain, fragile if they are an OpenWrt firewall
  include, which is loaded at firewall-start). The ordering intent is undocumented and untested.
- There is **no `STOP=`**. Stock convention pairs `START` with a `STOP` for the `K` symlink so a
  running daemon and its rules are torn down deterministically before network teardown at shutdown.
  With `STOP` unset, `enable()` (`rc.common:47-51`) creates only the `S90` symlink and never a `K`
  link — the service is not explicitly stopped in the shutdown path and relies on process kill
  ordering.

Concrete fix: state ordering explicitly and back it with a number that reflects the F1 design (if
rules are installed by this package, they must load after `network` and be torn down before it);
add a `STOP=` value (e.g. `STOP=10`) so the `K` symlink exists and teardown is ordered; document the
intended relative order (`network=20 < mptcp-bonding=90`, and the firewalling consumer) in the
header comment. Also note `init.d:3-5` claims the kernel PM "splits that single connection" but does
not state the ordering dependency on `network`/WAN being up.

---

### F5 — MINOR — `subflows` is written to the kernel without any numeric validation, and `suflows`/`0` semantics are not enforced

File: `net/mptcp-bonding/files/etc/init.d/mptcp-bonding:22` and `:35-37`
Quoted:
```
	config_get subflows   main subflows 2
```
```
	[ -w /proc/sys/net/mptcp/subflows ] 2>/dev/null && \
		echo "$subflows" > /proc/sys/net/mptcp/subflows 2>/dev/null
```
and `config:16-17`:
```
	# Max subflows the kernel may open per connection (0 = unlimited).
	option subflows '2'
```

Why it is wrong: `$subflows` is interpolated straight into a `>` redirect with no `case`/regex
numeric guard. An operator value such as `subflows '2 '` (trailing space) or a non-numeric string
will either be rejected by the kernel silently (the `2>/dev/null` swallows the error, so it fails
**quietly** — see F8) or, worse for a value that happens to parse, set an unintended cap. Also, the
`config:16` comment asserts `0 = unlimited`, but `0` is not a documented "unlimited" sentinel for
this knob in the way the comment implies, and nothing in the script translates `0` into "no limit" —
it just writes `0`. Additionally, if `[ -w … ]` is false (kernel lacks the knob) the whole
subflow-cap feature silently does nothing but the service still starts "successfully", so a user who
set `subflows 4` gets a single/double-path service and no warning.

Concrete fix: validate with e.g. `case "$subflows" in ''|*[!0-9]*) echo … >&2; return 1;; esac`
before the write; treat `0` explicitly (either document it as "leave kernel default" and skip the
write, or translate); and emit a `WARNING … >&2` when `/proc/sys/net/mptcp/subflows` is not
writable so the missing capability is visible rather than silent. (Also cross-check against the
sibling setup-bond.sh writer of the same path, per F3.)

---

### F6 — MINOR — the transparency/`-u` flags on the `ss-redir` command are never explained and `-u` changes UDP behaviour that the (absent) rules would have to match

File: `net/mptcp-bonding/files/etc/init.d/mptcp-bonding:40-42`
Quoted:
```
	procd_set_param command "$SS_REDIR" \
		-s "$server" -p "$port" -k "$password" -m "$cipher" \
		-b "0.0.0.0" -l "$local_port" -u
```
Why it is wrong: `-u` enables the UDP relay. Combined with F1 (no rules at all) neither TCP nor UDP
is actually redirected, so `-u` is currently dead weight; and once F1 is fixed the redirect rules
must cover UDP as well, otherwise the flag is a lie in the other direction. It is also the only
place the "transparent proxy" nature is implied on the command side, yet nothing makes the process
transparent (no `iptables -t nat REDIRECT`). Separately, `-b "0.0.0.0"` exposes the local port on
**all** interfaces including WAN — for a transparent-proxy listener that is normally meant to be
bound to loopback (`-b 127.0.0.1`) and reached only via REDIRECT. Binding `0.0.0.0` makes the
shadowsocks port remotely reachable.

Concrete fix: either drop `-u` (if only TCP is intended) or explicitly document and cover UDP in the
redirect rules; change `-b "0.0.0.0"` to `-b "127.0.0.1"` unless there is a documented reason the
port must be reachable from the LAN/WAN, and say why in the header comment.

---

### F7 — MINOR — `procd_set_param respawn` uses bare defaults, no `file`/`pidfile`, no explicit limit; a crash loop is bounded only by procd's global defaults

File: `net/mptcp-bonding/files/etc/init.d/mptcp-bonding:43`
Quoted:
```
	procd_set_param respawn
```
Why it is wrong: `respawn` with no arguments uses procd's defaults (threshold 3600s / 5s / 5 fails
per `procd.sh` docs cited in the script header usage). That is not insane, but it is *unstated*, and
the checklist asks for "sane thresholds". More importantly there is **no `procd_set_param file`
and no `pidfile`**: because the command is a fixed argv built from UCI at start time, procd's
"file" trigger (auto-restart/watch on a config file) is not used, which is fine given F3's reload
approach, but the absence should be a conscious choice. There is no `procd_set_param limits` either,
so a runaway ss-redir is unconstrained.

Concrete fix: either keep bare `respawn` and document why, or make it explicit
(`procd_set_param respawn 3600 5 5`) with a one-line rationale. Consider `procd_set_param limits`
if the device is resource-constrained (this targets routers).

---

### F8 — MINOR — silent-failure paths: the sysctl write and the kernel errors it can produce are sent to `/dev/null`, and the "disabled" path exits 0 with only a stderr note

Files/lines: `init.d:36-37`, `init.d:24`, `init.d:30-33`
Quoted:
```
	[ -w /proc/sys/net/mptcp/subflows ] 2>/dev/null && \
		echo "$subflows" > /proc/sys/net/mptcp/subflows 2>/dev/null
```
```
	[ "$enabled" = "1" ] || { echo "mptcp-bonding: disabled" >&2; return 0; }
```
```
	[ -x "$SS_REDIR" ] || {
		echo "mptcp-bonding: $SS_REDIR missing (install shadowsocks-libev-ss-redir)" >&2
		return 1
	}
```
What is CORRECT here: the presence checks `init.d:24` (disable gate) and `init.d:30-33`
(binary-exists check) **do** log to stderr and **do** return non-zero on the hard failure
(`return 1`) — that part satisfies "fail loudly rather than silently". `procd_set_param stderr 1`
(`:45`) also ensures daemon stderr reaches syslog. Good.

Why the remainder is wrong: the sysctl write at `:36-37` is the one operation whose failure is
entirely swallowed (`2>/dev/null` on both the test and the write), so a user who set `subflows 4`
on a kernel without the knob, or whose write was rejected, sees nothing failable. Combined with F5
(no validation) the subflow cap is the least-observable and least-guarded part of the script, while
being one of its two advertised features (`init.d:4-5`).

Concrete fix: remove the `2>/dev/null` on the write (let the kernel error surface to stderr, which
`stderr 1` already routes to syslog), or capture it and emit a `mptcp-bonding: failed to set
subflow cap` warning. Do not silence the only operation that can silently defeat the feature.

---

### F9 — NIT — header comment attributes MPTCP enablement to the sysctl file but the script relies on a global path that the script itself writes, and the comment/behaviour split invites confusion

File: `net/mptcp-bonding/files/etc/init.d/mptcp-bonding:3-5`
Quoted:
```
# Brings up a shadowsocks ss-redir toward the convergence-point VPS; the kernel
# MPTCP path manager (enabled via /etc/sysctl.d/mptcp-bonding.conf) splits that
# single connection across the router's upstream WAN links as subflows.
```
Why it is a nit (not higher): the comment is a fair summary of intent; the problem is that
"enabled via /etc/sysctl.d/mptcp-bonding.conf" implies the init script depends on that file having
been applied, but there is no check, and the same script then *itself* writes into the neighbouring
`/proc/sys/net/mptcp/subflows` (`:36-37`) — so responsibility for "MPTCP is configured" is split
across three owners (the sysctl file, this init script, and setup-bond.sh). (The correctness of the
*sysctl file's own* settings is explicitly out of scope and owned by another task.)

Concrete fix: add one line to the header naming the actor for each concern ("sysctl.d sets
`net.mptcp.enabled`/`pm_type`; this script sets the per-connection subflow cap; `setup-bond.sh`
manages endpoints"), and add a cheap precondition log if `net.mptcp.enabled` is not `1` at start.

---

## CHECKED AND FOUND CORRECT

### C1 — Scaffolding

- `init.d:1` `#!/bin/sh /etc/rc.common` — CORRECT. This is the required shebang for an OpenWrt
  init script; the interpreter is `/etc/rc.common` sourced via `sh` (it is a POSIX shell, no bash
  isms in the file).
- `init.d:8` `USE_PROCD=1` — CORRECT and present.
- No mixed non-procd bodies: the file defines **only** `start_service()` and `service_triggers()`;
  there is **no** legacy `start()`/`stop()`/`boot()`/`restart()` override, so `rc.common`'s
  procd-aware wrappers (`rc.common:137-172`) are the sole entry points. No procd/non-procd mix.
- `init.d:49-51` — `procd_add_reload_trigger mptcp-bonding` is declared while a reload command
  exists implicitly via `rc.common` (reload is always a valid command; `EXTRA_COMMANDS`/`EXTRA_HELP`
  are only needed for *custom* commands). Since no custom command is added, the absence of
  `EXTRA_COMMANDS`/`EXTRA_HELP` is CORRECT (`rc.common:72-77, 187-188` — extras are purely
  additive). The trigger name `mptcp-bonding` matches the `config_load mptcp-bonding` /
  `/etc/config/mptcp-bonding` package name — CORRECT.

### C2 — Service definition

- `init.d:39`/`:46` `procd_open_instance` … `procd_close_instance` — CORRECT, properly paired,
  exactly one instance.
- `init.d:40-42` `procd_set_param command "$SS_REDIR" \ -s "$server" -p "$port" -k "$password" -m
  "$cipher" \ -b "0.0.0.0" -l "$local_port" -u` — CORRECT **quoting discipline**: `command` takes
  argv as separate shell words, one option per string; every interpolated value is double-quoted, so
  a password/cipher containing spaces or `;` cannot split the argument or inject. The absolute path
  `SS_REDIR=/usr/bin/ss-redir` (`:10`) is the path the installed `shadowsocks-libev-ss-redir`
  package provides, consistent with `Makefile:20,30` which pull in that dependency. (Design issues
  with the *choice* of flags are F6, not a quoting error.)
- `init.d:44-45` `procd_set_param stdout 1` / `procd_set_param stderr 1` — CORRECT, and this is what
  makes the stderr diagnostics in `:24`/`:27`/`:31` discoverable in syslog.
- No `procd_set_param file`/`pidfile` — noted as a conscious-gap finding (F7), not a correctness
  error on its own.
- `init.d:43` `procd_set_param respawn` — syntactically CORRECT (bare form is valid); thresholds
  left default (see F7).

### C3 — Required-config validation before start

- `init.d:26-29` — the server/password presence gate is CORRECT in *intent*, in *precedence*, and it
  does fail loudly (`return 1` + stderr). I explicitly tested the "tricky" line
  `[ -z "$server" ] || [ -z "$password" ] && { … }` for the left-associativity trap under both
  `bash` and `dash`, with all four combinations of (server set/empty) × (password set/empty):
  result was `NOBAIL` when **both** are set, and `BAIL` in the other three cases — i.e. it refuses
  exactly when either value is missing, which is the intended semantics. (`||` and `&&` are equal
  precedence, left-associative in POSIX sh, so the expression is `(A || B) && C`, and `C` runs only
  when `A||B` is true.) **CORRECT — no finding.** Byte-for-byte consistency of the bail value with
  the config's empty-string defaults (`config:7`, `config:11`) also holds.
- `init.d:24` enabled-gate `[ "$enabled" = "1" ]` — CORRECT string comparison against the UCI value
  `'1'`; returns 0 with a stderr note when disabled (intended behaviour: a disabled service is a
  clean no-op, not an error).

### C4 — Lifecycle: reload actually re-reads UCI (the sibling doc's claim, verified precisely)

- `init.d:49-51` + authoritative `rc.common:165-172` + `rc.common:137-142`: with `USE_PROCD=1` and
  no `reload_service()`, `reload()` falls to `start()` → `rc_procd start_service` →
  `procd_open_service … procd_close_service set`. `set` (not `add`) replaces the instance, and
  `start_service()` re-runs `config_load mptcp-bonding` (`:15`) and all `config_get`s (`:16-22`).
  Therefore **changed UCI values ARE applied on reload** — reload is NOT a silent no-op. CORRECT
  for the config values. (What reload does not handle is the F1/F2/F3 state-teardown/re-add problem;
  that is captured as findings, not as a reload-correctness failure.)
- `stop()` teardown of the *daemon* is handled by procd itself (`procd_kill`, `rc.common:156-163`),
  so the process does stop on `stop`/`reload`. CORRECT as far as the process goes; the missing
  `stop_service()` matters only for non-procd state (F2).

### C5 — UCI ↔ init cross-check matrix (1:1)

Every option the init script reads is compared against the shipped config. All `config_get` calls
are on section `main` of package `mptcp-bonding`; the shipped config defines section `main 'main'`
(`config:4`). Section name and package name match.

| init reads (file:line) | option | section | init default | config defines (file:line) | shipped value | match? |
|---|---|---|---|---|---|---|
| `init.d:16` `config_get enabled main enabled 0` | `enabled` | main | `0` | `config:5` `option enabled '0'` | `0` | MATCH (name, section, default) |
| `init.d:17` `config_get server main server` | `server` | main | (none/empty) | `config:7` `option server ''` | `''` | MATCH |
| `init.d:18` `config_get port main server_port 65101` | `server_port` | main | `65101` | `config:9` `option server_port '65101'` | `65101` | MATCH (incl. default) |
| `init.d:19` reads secret option `main`/secret-key (`config_get`) | secret-key option | main | (none/empty) | `config:11` ships empty string | `''` | MATCH |
| `init.d:20` `config_get cipher main cipher aes-256-gcm` | `cipher` | main | `aes-256-gcm` | `config:13` `option cipher 'aes-256-gcm'` | `aes-256-gcm` | MATCH (incl. default) |
| `init.d:21` `config_get local_port main local_port 1081` | `local_port` | main | `1081` | `config:15` `option local_port '1081'` | `1081` | MATCH (incl. default) |
| `init.d:22` `config_get subflows main subflows 2` | `subflows` | main | `2` | `config:17` `option subflows '2'` | `2` | MATCH (incl. default) |

- **Options read but not defined in the shipped config: NONE.** (All 7 reads have a matching
  `option` line.)
- **Options defined but never read by the init script: NONE.** (All 7 defined options are read.
  Note the shipped `enabled`'s *header comment* tells users to set
  `mptcp-bonding.main.enabled=1` (`config:2`), which is exactly the value the gate at `init.d:24`
  tests — consistent.)
- **Type check:** all seven are plain `option` (scalar string) entries, matching `config_get`
  (scalar) usage; none is erroneously declared `list` or `option … 'true'/'false'`. The one
  boolean-ish option, `enabled`, is compared against the string `"1"` in `init.d:24`, and the config
  ships it as `'0'` — UCI 0/1 convention, **not** `true`/`false`. CORRECT.
- **No `default_config()`/`defaults` function exists** in the init script (confirmed by grep for
  `default_config`, `EXTRA_COMMAND`, etc. — none present). The "defaults" role is played entirely by
  the inline `config_get` fallback arguments listed above, and those agree with the shipped values.
  This is a legitimate pattern; the only consequence is that the two sources of truth (config file
  values vs `config_get` fallbacks) are duplicated, so they must be kept in sync by hand — currently
  they are in sync.
- **Hardcoded constants:** the value `65101` is hardcoded in the init default (`init.d:18`) *and* as
  the shipped config value (`config:9`); `1081` likewise (`init.d:21`, `config:15`). They agree, and
  each is overridable via UCI. `SS_REDIR=/usr/bin/ss-redir` (`init.d:10`) is hardcoded and NOT
  configurable — acceptable (it is the packaged binary path), but see F6/C2 for why the path is
  correct. (The sibling docs note 65101 appears a third time in setup-bond.sh:267 — cross-file
  consistency, out of this task's scope.)

### C6 — Log/error paths (partial pass)

- Discoverable logging: CORRECT — `procd_set_param stdout 1` / `stderr 1` (`:44-45`) route the
  daemon's output to syslog, and every init-script diagnostic uses `>&2` (`:24, :27, :31`).
- Fails loudly on the hard prerequisites: CORRECT — missing `ss-redir` returns 1 with a stderr
  message (`:30-33`); missing server/password returns 1 with a stderr message (`:26-29`, modulo the
  precedence observation in C3).
- Not-silent on the *subflow* path: FAILS (the only swallowed failure) — see F5/F8.

---

## VERDICT

Content-correctness gate: **FAIL** — 1 BLOCKER (F1: no redirection path exists, so the service
cannot perform its advertised function), 3 MAJOR (F2 no `stop_service`/teardown hook, F3 reload
state-handling + dual global-sysctl writer, F4 ordering/`STOP=` unspecified), 4 MINOR (F5 unvalidated
subflows write, F6 `-u`/`0.0.0.0` exposure, F7 bare `respawn`/no limits, F8 silent sysctl failure),
1 NIT (F9 split-ownership commentary). Scaffolding, procd instance definition, quoting, the UCI↔init
option matrix, and the "reload re-reads UCI" claim are CHECKED AND FOUND CORRECT (C1–C6). Total: 9
findings (1 blocker / 3 major / 4 minor / 1 nit).

Nothing in this review required CI, and no CI was run (per task).
