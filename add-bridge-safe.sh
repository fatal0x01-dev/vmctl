#!/usr/bin/env bash
set -euo pipefail
PHYS_IF="eno1"
BRIDGE="br0"

ip link add name "$BRIDGE" type bridge 2>/dev/null || true
ip link set "$BRIDGE" up
ip link set "$PHYS_IF" master "$BRIDGE"

# move the IP from the physical iface to the bridge
IP_CIDR=$(ip -4 addr show "$PHYS_IF" | awk '/inet /{print $2}')
GATEWAY=$(ip route | awk '/default/{print $3}')

ip addr flush dev "$PHYS_IF"
ip addr add "$IP_CIDR" dev "$BRIDGE"
ip route add default via "$GATEWAY" dev "$BRIDGE" 2>/dev/null || true

echo "[*] Done. $BRIDGE now holds $IP_CIDR"
