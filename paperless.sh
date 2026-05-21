#!/usr/bin/env bash
# paperless.sh — bring up paperless-ngx on apple/container.
#
#   ./paperless.sh up [--with-tika] [--with-gotenberg]
#   ./paperless.sh down
#   ./paperless.sh status
#   ./paperless.sh logs [service]
#   ./paperless.sh exec  [service] <cmd...>
#   ./paperless.sh createsuperuser

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# apple/container only auto-registers containers into a DNS domain on the
# `default` network — custom networks get an IP but no name records. So we
# share the default network and rely on the DNS domain for service discovery.
NETWORK="default"
DNS_DOMAIN="paperless.local"
# Default subnet (192.168.64.0/24) collides with split-tunnel exceptions some
# VPNs (e.g. Tailscale exit nodes) push for RFC1918 ranges, which sends host→
# container traffic out the wifi gateway. Move to a less-trafficked /24 and,
# if needed, install a more-specific route via the container bridge.
CONTAINER_SUBNET="10.64.0.0/24"
CONTAINER_BRIDGE="bridge100"
WEB_IMAGE="ghcr.io/paperless-ngx/paperless-ngx:latest"
REDIS_IMAGE="docker.io/library/redis:8"
DB_IMAGE="docker.io/library/postgres:18"
TIKA_IMAGE="docker.io/apache/tika:latest"
GOTENBERG_IMAGE="docker.io/gotenberg/gotenberg:8"
TAILSCALE_IMAGE="docker.io/tailscale/tailscale:latest"

ENV_FILE="$SCRIPT_DIR/paperless.env"
ENV_EXAMPLE="$SCRIPT_DIR/paperless.env.example"

# Persistent state lives under ./state (volumes) and ./consume + ./export
# (bind-mounted folders the user actually drops files into).
STATE_DIR="$SCRIPT_DIR/state"
PGDATA="$STATE_DIR/pgdata"
REDISDATA="$STATE_DIR/redisdata"
PAPERLESS_DATA="$STATE_DIR/paperless-data"
PAPERLESS_MEDIA="$STATE_DIR/paperless-media"
TAILSCALE_STATE="$STATE_DIR/tailscale"
CONSUME_DIR="$SCRIPT_DIR/consume"
EXPORT_DIR="$SCRIPT_DIR/export"
TAILSCALE_SERVE_JSON="$SCRIPT_DIR/tailscale-serve.json"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# --- preflight --------------------------------------------------------------

preflight() {
  command -v container >/dev/null \
    || die "apple/container CLI not found. Install from https://github.com/apple/container"

  local macos_major
  macos_major=$(sw_vers -productVersion | cut -d. -f1)
  if [[ "$macos_major" -lt 26 ]]; then
    die "macOS 26+ required (inter-container DNS doesn't work on 15). Got $(sw_vers -productVersion)."
  fi

  # System service must be running for network/run commands.
  container system status >/dev/null 2>&1 || {
    log "starting container system service"
    container system start
  }
}

ensure_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    log "generating $ENV_FILE from template"
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    local secret
    secret=$(openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-50)
    # macOS sed -i needs an empty backup suffix arg.
    sed -i '' "s|^PAPERLESS_SECRET_KEY=.*|PAPERLESS_SECRET_KEY=$secret|" "$ENV_FILE"
    warn "default DB password is 'paperless' — edit $ENV_FILE before exposing this."
  fi
}

ensure_dirs() {
  mkdir -p "$PGDATA" "$REDISDATA" "$PAPERLESS_DATA" "$PAPERLESS_MEDIA" \
           "$TAILSCALE_STATE" "$CONSUME_DIR" "$EXPORT_DIR"
}

ensure_network() {
  # `default` is created by `container system start`; nothing to do unless
  # the user later switches to a named network.
  if [[ "$NETWORK" != "default" ]] && \
     ! container network list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$NETWORK"; then
    log "creating network $NETWORK"
    container network create "$NETWORK"
  fi
}

ensure_route() {
  # If the host's route to the container subnet doesn't land on bridge100,
  # something else (VPN split-tunnel rules, leftover DHCP routes) is hijacking
  # it. Replace with an interface route via the bridge so --publish works.
  local iface
  iface=$(route -n get -net "$CONTAINER_SUBNET" 2>/dev/null | awk '/interface:/ {print $2}')
  if [[ "$iface" == "$CONTAINER_BRIDGE" ]]; then
    return 0
  fi

  log "host route for $CONTAINER_SUBNET points at $iface, need $CONTAINER_BRIDGE"
  # Prime sudo if a tty is available, then run the fix. If we can't prompt,
  # tell the user the exact one-liner and keep going — they can run it any
  # time before they actually try to hit localhost:8000.
  if [[ -t 0 ]] && sudo -v 2>/dev/null; then
    sudo route -n delete -net "$CONTAINER_SUBNET" >/dev/null 2>&1 || true
    sudo route -n delete -net "$CONTAINER_SUBNET" -ifscope "$CONTAINER_BRIDGE" >/dev/null 2>&1 || true
    sudo route -n add    -net "$CONTAINER_SUBNET" -interface "$CONTAINER_BRIDGE"
  else
    warn "no interactive sudo — run this manually so host→container forwarding works:"
    warn "  sudo route -n delete -net $CONTAINER_SUBNET ; sudo route -n add -net $CONTAINER_SUBNET -interface $CONTAINER_BRIDGE"
  fi
}

ensure_dns() {
  # apple/container doesn't auto-resolve bare service names. Three things are
  # needed: (1) register the domain (creates /etc/resolver entry + an internal
  # DNS server on 127.0.0.1:2053), (2) set dns.domain as the system default so
  # the runtime registers each new container into the domain automatically,
  # (3) pass --dns-search on `container run` so containers resolve bare names.
  if ! container system dns list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$DNS_DOMAIN"; then
    log "registering DNS domain $DNS_DOMAIN (needs sudo)"
    sudo container system dns create "$DNS_DOMAIN"
  fi
  local current
  current=$(container system property get dns.domain 2>/dev/null || true)
  if [[ "$current" != "$DNS_DOMAIN" ]]; then
    log "setting dns.domain=$DNS_DOMAIN"
    container system property set dns.domain "$DNS_DOMAIN"
  fi
}

# --- container helpers ------------------------------------------------------

exists() { container list --all --format json 2>/dev/null | grep -q "\"$1\""; }

start_one() {
  local name="$1"; shift
  if exists "$name"; then
    # If it's running, leave it. If stopped, drop it so we recreate with
    # current config (mounts/env may have changed since the last run).
    if container list --format json 2>/dev/null | grep -q "\"$name\""; then
      log "$name already running"
      return
    fi
    log "removing stopped $name to recreate"
    container rm "$name" >/dev/null 2>&1 || true
  fi
  log "running $name"
  container run --detach --name "$name" --network "$NETWORK" \
    --dns-search "$DNS_DOMAIN" --dns-domain "$DNS_DOMAIN" "$@"
}

wait_for_db() {
  log "waiting for postgres to accept connections"
  for _ in $(seq 1 60); do
    if container exec db pg_isready -U paperless >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "postgres didn't come up within 60s — check 'container logs db'"
}

# --- service definitions ----------------------------------------------------

start_broker() {
  start_one broker \
    --volume "$REDISDATA:/data" \
    "$REDIS_IMAGE"
}

start_db() {
  # Postgres 18 image expects the volume at /var/lib/postgresql (the parent),
  # not /var/lib/postgresql/data — it places versioned subdirs inside so
  # pg_upgrade --link works cleanly. See docker-library/postgres#1259.
  start_one db \
    --env-file "$ENV_FILE" \
    --volume "$PGDATA:/var/lib/postgresql" \
    "$DB_IMAGE"
}

start_webserver() {
  # Optional runtime overrides for Tika/Gotenberg are appended below — they
  # win over whatever's in $ENV_FILE because later --env beats --env-file.
  local extra_env=()
  (( WITH_TIKA )) && extra_env+=(
    --env PAPERLESS_TIKA_ENABLED=1
    --env PAPERLESS_TIKA_ENDPOINT=http://tika:9998
  )
  (( WITH_GOTENBERG )) && extra_env+=(
    --env PAPERLESS_TIKA_GOTENBERG_ENDPOINT=http://gotenberg:3000
  )
  start_one webserver \
    --env-file "$ENV_FILE" \
    "${extra_env[@]}" \
    --publish 8000:8000 \
    --volume "$PAPERLESS_DATA:/usr/src/paperless/data" \
    --volume "$PAPERLESS_MEDIA:/usr/src/paperless/media" \
    --volume "$CONSUME_DIR:/usr/src/paperless/consume" \
    --volume "$EXPORT_DIR:/usr/src/paperless/export" \
    "$WEB_IMAGE"
}

start_tika()      { start_one tika      "$TIKA_IMAGE"; }
# Unlike Docker, apple/container's `run <image> <args...>` replaces the whole
# ENTRYPOINT — so passing extra gotenberg flags here means we'd have to
# re-state the entrypoint binary. The defaults work fine; revisit only if
# the Chromium sandbox actually breaks in the microVM.
start_gotenberg() { start_one gotenberg "$GOTENBERG_IMAGE"; }

# Sidecar that joins our tailnet and HTTPS-proxies it to the webserver. Runs
# in userspace mode (TS_USERSPACE=true) so it doesn't need /dev/net/tun or
# NET_ADMIN, which would be awkward in apple/container's microVM model.
# The serve config tells tailscaled to terminate tailnet HTTPS and proxy to
# http://webserver:8000 (resolved via the apple/container DNS domain).
start_tailscale() {
  local authkey
  authkey=$(grep -E '^TS_AUTHKEY=.+' "$ENV_FILE" | cut -d= -f2-)
  [[ -n "$authkey" ]] \
    || die "TS_AUTHKEY is empty in $ENV_FILE — get one at https://login.tailscale.com/admin/settings/keys and set it before --with-tailscale"
  # State intentionally lives inside the container's writable layer rather
  # than a bind mount: apple/container's virtiofs rejects the chmod 0700 that
  # tailscaled does on its state dir, so tailscaled falls back to in-memory
  # state and refuses to start. With a reusable TS_AUTHKEY the node simply
  # re-registers on each recreate. The serve.json bind is read-only, no
  # chmod, so it's safe.
  start_one tailscale \
    --env-file "$ENV_FILE" \
    --env TS_USERSPACE=true \
    --env TS_STATE_DIR=/var/lib/tailscale \
    --env TS_SERVE_CONFIG=/config/serve.json \
    --volume "$TAILSCALE_SERVE_JSON:/config/serve.json" \
    "$TAILSCALE_IMAGE"
}

# --- commands ---------------------------------------------------------------

cmd_up() {
  WITH_TIKA=0
  WITH_GOTENBERG=0
  WITH_TAILSCALE=0
  for arg in "$@"; do
    case "$arg" in
      --with-tika)      WITH_TIKA=1 ;;
      --with-gotenberg) WITH_GOTENBERG=1 ;;
      --with-tailscale) WITH_TAILSCALE=1 ;;
      *) die "unknown flag: $arg" ;;
    esac
  done

  preflight
  ensure_env
  ensure_dirs
  ensure_network
  ensure_dns
  # Only worry about the kernel-route hack if the user actually needs the
  # host-loopback --publish path. With --with-tailscale they reach paperless
  # over the tailnet, where bridge routing is irrelevant.
  (( WITH_TAILSCALE )) || ensure_route

  start_broker
  start_db
  wait_for_db
  (( WITH_TIKA ))      && start_tika
  (( WITH_GOTENBERG )) && start_gotenberg
  start_webserver
  (( WITH_TAILSCALE )) && start_tailscale

  if (( WITH_TAILSCALE )); then
    local hostname
    hostname=$(grep -E '^TS_HOSTNAME=' "$ENV_FILE" | cut -d= -f2-)
    log "stack is up. paperless-ngx → https://${hostname:-paperless}.<your-tailnet>.ts.net"
    log "tailscale needs ~10s on first run. tail it with: $0 logs tailscale"
  else
    log "stack is up. paperless-ngx → http://localhost:8000"
  fi
  log "first run? create an admin with: $0 createsuperuser"
}

cmd_down() {
  for svc in tailscale webserver gotenberg tika db broker; do
    if exists "$svc"; then
      log "stopping $svc"
      container stop "$svc" >/dev/null 2>&1 || true
      container rm   "$svc" >/dev/null 2>&1 || true
    fi
  done
}

cmd_status() { container list --all; }

cmd_logs() {
  local svc="${1:-webserver}"
  container logs --follow "$svc"
}

cmd_exec() {
  local svc="${1:-webserver}"; shift || true
  [[ $# -gt 0 ]] || die "usage: $0 exec [service] <cmd...>"
  container exec --interactive --tty "$svc" "$@"
}

cmd_createsuperuser() {
  container exec --interactive --tty webserver python manage.py createsuperuser
}

# --- dispatch ---------------------------------------------------------------

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    up)              cmd_up "$@" ;;
    down)            cmd_down ;;
    status)          cmd_status ;;
    logs)            cmd_logs "$@" ;;
    exec)            cmd_exec "$@" ;;
    createsuperuser) cmd_createsuperuser ;;
    -h|--help|help|"") usage 0 ;;
    *) usage 1 ;;
  esac
}

main "$@"
