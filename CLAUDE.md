# Notes for future Claude sessions

**This is a PUBLIC repo. Never commit identifying details**: tailnet names, ts.net hostnames, machine/node names, public or LAN IPs, MAC addresses, emails. Use placeholders like `<mac-node-name>.<tailnet>.ts.net` or "the LAN gateway" in docs. (Absolute `/Users/damian/...` paths in the launchd plists are functionally required and acceptable.) Before any commit touching docs, grep the diff for `ts\.net|@|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+` and genericize non-RFC1918/non-container addresses.

This project orchestrates [paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) under Apple's [`container`](https://github.com/apple/container) CLI on macOS 26+. Everything is driven by `paperless.sh`; there's no docker-compose because `container` doesn't support it.

## What's in the script that you'd never guess from `container --help`

These are behavioral quirks of `container` discovered empirically — originally on 0.12.x, re-verified/updated on **1.1.0** (2026-07-09, installed via `brew install container`). Don't "fix" them without understanding why:

1. **`container run <image> <args>` replaces the entire ENTRYPOINT**, not just CMD. To pass flags to an image's entrypoint (e.g. `gotenberg --chromium-disable-routes`), you have to re-state the entrypoint binary. Easier to just leave defaults. (Documented on 0.12.x; not re-verified on 1.x.)
2. **Service-name DNS needs two things** (1.x): `sudo container system dns create <domain>` (one-time, survives reboots, also gives the *host* name resolution via `/etc/resolver`), and `domain = "<domain>"` under `[dns]` in `~/.config/container/config.toml`. The old `container system property get/set dns.domain` commands were **removed in 1.0** — the config file replaced them, and it's only read at `container system start`, so config changes need a service bounce. With both in place, bare names resolve from containers and FQDNs (`webserver.paperless.local`) resolve from the host too.
3. **DNS auto-registration only works on the `default` network.** Custom networks get IPs but no name records. Don't refactor to a project-named network unless you're prepared to lose service discovery. (Documented on 0.12.x; not re-verified on 1.x.)
4. **The `default` network's subnet is set via `[network] subnet` in config.toml** (1.x) — no more nuking `networks/default/`. But **vmnet only accepts RFC1918 subnets**: setting a non-private range (tried `198.18.64.0/24` to dodge Tailscale) makes `container system start` hang forever with no error. Recovery from that wedge: `launchctl bootout gui/501/com.apple.container.<apiserver|container-core-images|container-network-vmnet.default|machine-apiserver>`, `pkill -9 -f container-apiserver`, fix the config, start again.
5. **`--publish` does kernel-level forwarding via the bridge**, not a userspace proxy. If the host's route to the container subnet is hijacked, `--publish` silently fails — TCP connects locally but no data flows.
6. **virtiofs `chmod` from the guest works as of 1.1.0** (verified on bind mounts and named volumes) — **except on the mount point itself**, which still returns EPERM. Anything that chmods its state dir (tailscaled does) must point at a *subdirectory* of the mount, not the mount root — hence `TS_STATE_DIR=/var/lib/tailscale/data` with the volume at `/var/lib/tailscale`.
7. **First-ever `container system start` interactively prompts to install a kernel** and hangs without a tty. `container system kernel set --recommended` does it non-interactively; preflight handles this.

## Environmental conflict — root-caused, handled by a LaunchDaemon (2026-07-09)

The user runs **Tailscale with an exit node**. The culprit is the client's **"Allow local network access"** setting (`ExitNodeAllowLANAccess`): on macOS it installs a gateway route for *every* RFC1918 connected subnet toward the LAN gateway (`10.64/24 → <lan-gateway> via en0`), clobbering `bridge100`'s connected route. That breaks both host→container (`--publish`, direct IP) and container→internet (NAT return path). Known open Tailscale bug — also bites OrbStack (orbstack/orbstack#2297); there is no per-subnet exclusion knob.

**Don't suggest turning the setting off** — tested that; containers work and the router stays reachable via the scoped route, but the user's **printer breaks**, so the toggle must stay ON.

**The actual fix: `local.paperless.route` LaunchDaemon** (implemented, installed, verified). `route-guard.sh` runs as root, and every 10s re-pins `10.64.0.0/24` to `bridge100` if hijacked — but only while `bridge100` carries `10.64.0.1`, so it stays quiet when the stack is down. Repo copies are the source of truth; installed copies live at `/usr/local/libexec/paperless-route-guard.sh` + `/Library/LaunchDaemons/local.paperless.route.plist` (root-owned on purpose — a root daemon must not execute from the user-writable repo). Re-install after editing:

```
sudo cp route-guard.sh /usr/local/libexec/paperless-route-guard.sh
sudo launchctl bootout system/local.paperless.route; sudo launchctl bootstrap system /Library/LaunchDaemons/local.paperless.route.plist
```

Re-pin events log to syslog (`logger -t paperless-route`) and `/var/log/paperless-route.log`. Worst case after a Tailscale reconnect is ~10s of container-network outage. `ensure_route` remains in `paperless.sh` as a same-purpose safety net (runs after containers start, since bridge100 only exists while something is running).

**Current status (2026-07-09): the user disabled exit-node usage entirely**, so the hijack doesn't happen at all right now — no exit node means no LAN-access exception routes, regardless of the toggle. The daemon stays installed as insurance: it idles (the route check passes every tick) and automatically covers the user if they ever switch an exit node back on. Uninstall would be `sudo launchctl bootout system/local.paperless.route && sudo rm /Library/LaunchDaemons/local.paperless.route.plist /usr/local/libexec/paperless-route-guard.sh`.

## Tailscale sidecar caveats

- **State persists** in `state/tailscale/data` via bind mount (verified working 2026-07-09; note the `TS_STATE_DIR` subdirectory nuance in point #6). A reusable `TS_AUTHKEY` is still good practice but no longer burns on every recreate. `PAPERLESS_URL` in `paperless.env` is set to the ts.net URL for CSRF; if localhost login ever throws CSRF errors, add `PAPERLESS_CSRF_TRUSTED_ORIGINS=http://localhost:8000`.
- The sidecar runs in **userspace mode** (`TS_USERSPACE=true`) because it doesn't have `/dev/net/tun` or NET_ADMIN. `tailscale serve` works in userspace mode — HTTPS termination + reverse proxy to `http://webserver:8000` — **but is catastrophically slow** as of tailscale 1.98.8: gVisor netstack's Nagle + client delayed-ACK interaction ([tailscale/tailscale#18916](https://github.com/tailscale/tailscale/issues/18916), open) stalls ~200ms per few KB. Measured: ~450ms per TLS handshake, 232KB asset in 14s (~17KB/s). Applies equally to HTTPS proxy, HTTP proxy, and TCPForward — don't bother retuning serve.json; the bug is below that layer. Re-test with a newer tailscale image when the issue closes.
- **The fast path (2026-07-09): host-side `tailscale serve` on the Mac's native client** — `/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg 8000` → `https://<mac-node-name>.<tailnet>.ts.net` at ~60ms/connection, ~6MB/s (native kernel TCP, no netstack). Config persists in the client across reboots. `PAPERLESS_URL` points at this hostname; the sidecar URL stays as a slow fallback and its origin is in `PAPERLESS_CSRF_TRUSTED_ORIGINS`.

## Login-time start of the stack — DONE (2026-07-09)

`local.paperless.stack.plist` (repo copy is source of truth, installed at `~/Library/LaunchAgents/`) runs `paperless.sh up --with-tika --with-gotenberg --with-tailscale` at login. No "wait for container system" step needed — the script's preflight starts the system service itself. `KeepAlive.SuccessfulExit=false` + `ThrottleInterval=30` retries on failure, stops on success. Logs to `~/Library/Logs/paperless-stack.log`. It's a LaunchAgent (login), not a LaunchDaemon (boot) — apple/container is per-user, so login is as early as it gets. Reinstall after editing:

```
cp local.paperless.stack.plist ~/Library/LaunchAgents/
launchctl bootout gui/501/local.paperless.stack 2>/dev/null; launchctl bootstrap gui/501 ~/Library/LaunchAgents/local.paperless.stack.plist
```

## Deferred work

(none currently)

## Editing the script

- `start_one` recreates stopped containers automatically (it `rm`s them first), so config changes pick up on the next `up`. Running containers are left alone — if you need to change config on a running container, `down` first.
- Order in `cmd_up` matters. broker and db must be up before webserver. tika/gotenberg too if `--with-*` is passed, since paperless's env vars resolve to running services. tailscale comes last because it depends on webserver.
- `--env` after `--env-file` wins, which is how the runtime tika/gotenberg overrides work.

## Files

```
paperless.sh                  control script
paperless.env                 generated on first run from .example; contains secrets (NEVER COMMIT)
paperless.env.example         template
tailscale-serve.json          tailscale serve proxy config (committed, no secrets)
route-guard.sh                route-pinning daemon script (installed copy: /usr/local/libexec/paperless-route-guard.sh)
local.paperless.route.plist   LaunchDaemon for route-guard (installed copy: /Library/LaunchDaemons/)
local.paperless.stack.plist   login-time stack autostart LaunchAgent (installed copy: ~/Library/LaunchAgents/)
state/                        container data — postgres, redis, paperless DB+media, tailscale
consume/, export/             paperless drop/archive folders
```
