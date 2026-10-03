#!/usr/bin/env bash
# setup-br0.sh — create br0 bridge and attach eno1 for QEMU bridged networking
set -euo pipefail

PHYS_IF="eno1"
BRIDGE="br0"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo)." >&2
    exit 1
fi

if ip link show "$BRIDGE" &>/dev/null; then
    echo "[*] $BRIDGE already exists, skipping creation."
else
    echo "[*] Creating bridge $BRIDGE"
    ip link add name "$BRIDGE" type bridge
fi

echo "[*] Bringing up $BRIDGE"
ip link set "$BRIDGE" up

echo "[*] Attaching $PHYS_IF to $BRIDGE"
ip link set "$PHYS_IF" master "$BRIDGE"

echo "[*] Current bridge state:"
ip addr show "$BRIDGE"
bridge link show

echo
echo "NOTE: this is a runtime-only change and will not survive a reboot."
echo "To persist it, configure the bridge via netplan (see below) instead of running this script every boot."
