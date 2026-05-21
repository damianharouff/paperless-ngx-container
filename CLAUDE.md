# Notes for future Claude sessions

This project orchestrates [paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) under Apple's [`container`](https://github.com/apple/container) CLI on macOS 26+. Everything is driven by `paperless.sh`; there's no docker-compose because `container` doesn't support it.

## What's in the script that you'd never guess from `container --help`

These are behavioral quirks of `container` (0.12.x) discovered empirically. Don't "fix" them without understanding why:

1. **`container run <image> <args>` replaces the entire ENTRYPOINT**, not just CMD. To pass flags to an image's entrypoint (e.g. `gotenberg --chromium-disable-routes`), you have to re-state the entrypoint binary. Easier to just leave defaults.
2. **Service-name DNS needs three things together**: `sudo container system dns create <domain>` (one-time), `container system property set dns.domain <domain>` (one-time, no sudo), and `--dns-search <domain>` on every `container run`. Skip any of these and bare-name resolution silently returns NXDOMAIN.
3. **DNS auto-registration only works on the `default` network.** Custom networks get IPs but no name records. Don't refactor to a project-named network unless you're prepared to lose service discovery.
4. **The `default` network's subnet is fixed at first `container system start`** and can only be changed by stopping the service, removing `~/Library/Application Support/com.apple.container/networks/default/`, and restarting. The script assumes `10.64.0.0/24`; if the user's environment has it on `192.168.64.0/24`, they have to nuke and recreate.
5. **`--publish` does kernel-level forwarding via the bridge**, not a userspace proxy. If the host's route to the container subnet is hijacked, `--publish` silently fails — TCP connects locally but no data flows.
6. **Bind mounts go through virtiofs which rejects `chmod` from the guest.** Some images (notably `tailscale/tailscale`'s containerboot) break on this. The tailscale state directory is intentionally left inside the container's writable layer.

## Environmental conflict you'll keep tripping over

The user runs **Tailscale with an exit node enabled**. That installs split-tunnel `/24` routes for RFC1918 ranges, hijacking `10.64.0.0/24` away from `bridge100` toward the LAN gateway. Symptom: containers can't reach the internet, host can't reach `localhost:8000`. The script's `ensure_route` detects this and re-installs a `bridge100` route via sudo. Tailscale will keep clobbering it (bridge restart, Tailscale reconnect, reboot) — the long-term fix is a LaunchDaemon that owns the route (see "Deferred work" below).

The script also intentionally skips `ensure_route` when `--with-tailscale` is passed AND the user only intends to reach paperless over the tailnet — but containers still need outbound internet, so the route fix is currently always needed in practice.

## Tailscale sidecar caveats

- **State is ephemeral** (see point #6 above). Every container recreate re-auths against `TS_AUTHKEY`. The key in `paperless.env` must be **reusable** (Tailscale admin → Keys → Reusable), otherwise it burns after one boot.
- Untried alternative: apple/container named volumes (`container volume create`) might not go through virtiofs and could let us persist the state directory. Worth trying if the user complains about re-auth burn.
- The sidecar runs in **userspace mode** (`TS_USERSPACE=true`) because it doesn't have `/dev/net/tun` or NET_ADMIN. `tailscale serve` works fine in userspace mode — HTTPS termination + reverse proxy to `http://webserver:8000`.

## Deferred work (the user knows about these)

- **Boot-time start.** Designed but not implemented:
  - `/Library/LaunchDaemons/local.paperless.route.plist` — root, KeepAlive, loops every 30s checking that `10.64.0.0/24` lives on `bridge100`, re-adds if not.
  - `~/Library/LaunchAgents/local.paperless.stack.plist` — user, RunAtLoad, waits for `container system status` to be `running`, then invokes `paperless.sh up --with-tika --with-gotenberg --with-tailscale`.
  - Drop `ensure_route` from the user-mode script path once the daemon owns the route.
- **Persistent tailscale state via named volume** — see Tailscale caveats above.

## Editing the script

- `start_one` recreates stopped containers automatically (it `rm`s them first), so config changes pick up on the next `up`. Running containers are left alone — if you need to change config on a running container, `down` first.
- Order in `cmd_up` matters. broker and db must be up before webserver. tika/gotenberg too if `--with-*` is passed, since paperless's env vars resolve to running services. tailscale comes last because it depends on webserver.
- `--env` after `--env-file` wins, which is how the runtime tika/gotenberg overrides work.

## Files

```
paperless.sh             control script
paperless.env            generated on first run from .example; contains secrets (NEVER COMMIT)
paperless.env.example    template
tailscale-serve.json     tailscale serve proxy config (committed, no secrets)
state/                   container data — postgres, redis, paperless DB+media
consume/, export/        paperless drop/archive folders
```
