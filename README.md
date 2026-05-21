# paperless-ngx on apple/container

Run [paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) as a stack of native Linux containers under Apple's [`container`](https://github.com/apple/container) CLI on macOS 26+, with optional Apache Tika, Gotenberg, and a Tailscale sidecar that publishes the UI to your tailnet over HTTPS.

This is a one-script port of the upstream `docker/compose/docker-compose.postgres.yml`. No docker-compose required (apple's `container` doesn't support it yet).

## Requirements

- **macOS 26+** on Apple silicon. Earlier macOS doesn't have working inter-container DNS.
- **`container`** — `brew install container`. Tested against 0.12.3.
- Optional: a **Tailscale** account for `--with-tailscale`. Generate a *reusable* auth key at <https://login.tailscale.com/admin/settings/keys>.

## Quick start

```sh
# First run generates paperless.env with a random Django secret key.
./paperless.sh up

# Or with all add-ons:
./paperless.sh up --with-tika --with-gotenberg --with-tailscale

# Create the admin user (interactive).
./paperless.sh createsuperuser
```

Access:

- Local: `http://localhost:8000`
- Tailnet (with `--with-tailscale`): `https://<TS_HOSTNAME>.<your-tailnet>.ts.net`

## Configuration

`paperless.env` is created on first `up` from `paperless.env.example`. Edit it to:

- Replace the default Postgres password (`paperless`) before exposing the stack.
- Set OCR languages (`PAPERLESS_OCR_LANGUAGE=eng+fra+deu`).
- Set the time zone (`PAPERLESS_TIME_ZONE`).
- For Tailscale: set `TS_AUTHKEY` (reusable!) and `TS_HOSTNAME`.

`paperless.env` contains secrets and is **not** tracked by git — `paperless.env.example` is the version-controlled template.

## Commands

| Command | What it does |
|---|---|
| `./paperless.sh up [flags]` | Bring up the stack. Flags: `--with-tika`, `--with-gotenberg`, `--with-tailscale`. |
| `./paperless.sh down` | Stop and remove every container in the stack. Data is preserved (it's in `state/`). |
| `./paperless.sh status` | Show all containers, including stopped. |
| `./paperless.sh logs [service]` | Follow logs (default: `webserver`). |
| `./paperless.sh exec [service] <cmd>` | Run a command inside a container. |
| `./paperless.sh createsuperuser` | Django's `createsuperuser` inside the webserver. |

## Stack

| Container | Image | Purpose |
|---|---|---|
| `broker` | `redis:8` | Celery message bus |
| `db` | `postgres:18` | App database |
| `tika` (opt) | `apache/tika:latest` | Office document text extraction |
| `gotenberg` (opt) | `gotenberg/gotenberg:8` | PDF generation (Chromium + LibreOffice) |
| `webserver` | `paperless-ngx:latest` | Django + Granian, port 8000 |
| `tailscale` (opt) | `tailscale/tailscale:latest` | Userspace WireGuard, HTTPS proxy to webserver |

All images are pulled natively for `linux/arm64`. No Rosetta needed.

## Known limitations

- **No docker-compose.** Apple's `container` doesn't ship one. This script replaces it.
- **`--publish` is fragile under full-tunnel VPNs.** Apple's `container` does kernel-level port forwarding via its bridge interface — it has no userspace proxy like Docker Desktop. If something else (Tailscale exit node, NordVPN full mode, etc.) owns the default route and pushes split-tunnel `/24` exceptions for RFC1918 ranges, those override the container bridge route and both inbound `--publish` and outbound container internet break. The script detects this and reinstalls a `bridge100` route via sudo when interactive. For boot-time start, you need a LaunchDaemon (see notes in `CLAUDE.md`).
- **Tailscale sidecar state is ephemeral.** Apple's `container` virtiofs bind mounts reject `chmod`, which breaks `tailscaled`'s state directory permissioning. The container's state lives in its writable layer, so every recreate re-auths against `TS_AUTHKEY` — use a reusable key.
- **`PAPERLESS_TIKA_ENABLED` is auto-set when `--with-tika` is passed**; don't hard-set it in `paperless.env` unless you're sure tika is up.

## Layout

```
paperless.sh             control script
paperless.env.example    config template
paperless.env            generated; secrets, gitignored
tailscale-serve.json     tailscale serve config
state/                   postgres, redis, paperless data (gitignored)
consume/                 drop documents here for OCR (gitignored)
export/                  paperless export target (gitignored)
```
