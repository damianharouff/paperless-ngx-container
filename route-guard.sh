#!/bin/sh
# Keeps the host route for the apple/container subnet pinned to its bridge.
#
# Tailscale's "Allow local network access" (exit-node setting) re-installs a
# gateway route for every RFC1918 subnet toward the LAN gateway whenever it
# reconnects, hijacking the container subnet away from bridge100 and breaking
# both host->container traffic (--publish) and container outbound internet.
# The setting can't be turned off here — the user needs it for LAN devices
# (printer). So this daemon owns the route instead: whenever the subnet stops
# pointing at the bridge while the bridge is actually up, delete and re-add.
#
# Installed to /usr/local/libexec/paperless-route-guard.sh and run as root by
# /Library/LaunchDaemons/local.paperless.route.plist (KeepAlive). The repo
# copy is the source of truth; re-run the install step after editing.
#
# SUBNET/GATEWAY must match [network] subnet in ~/.config/container/config.toml.

SUBNET="10.64.0.0/24"
GATEWAY="10.64.0.1"
BRIDGE="bridge100"
INTERVAL=10

while :; do
  # Only act while the bridge is up and carries the container gateway —
  # otherwise there's nothing to route to (stack down, subnet changed).
  if /sbin/ifconfig "$BRIDGE" 2>/dev/null | /usr/bin/grep -q "inet $GATEWAY "; then
    iface=$(/sbin/route -n get -net "$SUBNET" 2>/dev/null | /usr/bin/awk '/interface:/ {print $2}')
    if [ "$iface" != "$BRIDGE" ]; then
      /sbin/route -n delete -net "$SUBNET" >/dev/null 2>&1
      /sbin/route -n add -net "$SUBNET" -interface "$BRIDGE" >/dev/null 2>&1
      /usr/bin/logger -t paperless-route "re-pinned $SUBNET to $BRIDGE (was ${iface:-unset})"
    fi
  fi
  sleep "$INTERVAL"
done
