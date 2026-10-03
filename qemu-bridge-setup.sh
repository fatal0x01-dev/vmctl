#!/usr/bin/env bash
# qemu-bridge-setup.sh
#
# Correctly configures a bridge (default: br0) over a physical interface
# (default: eno1) so QEMU's `-netdev bridge` works AND the host keeps its
# own network connectivity (the part the naive "just add eno1 to br0"
# approach breaks, because the host's IP has to live on the bridge, not
# on the enslaved physical NIC).
#
# Safe to re-run: it tears down any existing/half-broken br0 first.
#
# Usage:
#   sudo ./qemu-bridge-setup.sh [phys_iface] [bridge_name]
#   sudo ./qemu-bridge-setup.sh eno1 br0

set -euo pipefail

PHYS_IF="${1:-eno1}"
BRIDGE="${2:-br0}"
TIMEOUT=10

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo $0 [interface] [bridge]" >&2
    exit 1
fi

if ! ip link show "$PHYS_IF" &>/dev/null; then
    echo "[!] Interface '$PHYS_IF' does not exist. Available interfaces:" >&2
    ip -brief link show | awk '{print " -", $1}' >&2
    exit 1
fi

echo "=== QEMU bridge setup: $PHYS_IF -> $BRIDGE ==="

# --- 0. Tear down any existing / half-broken bridge state ---------------
echo "[*] Cleaning up any existing $BRIDGE"
if ip link show "$BRIDGE" &>/dev/null; then
    ip link set "$PHYS_IF" nomaster 2>/dev/null || true
    ip link set "$BRIDGE" down 2>/dev/null || true
    ip link delete "$BRIDGE" type bridge 2>/dev/null || true
fi

# --- 1. Capture the physical interface's current IPv4 config ------------
IP_CIDR=$(ip -4 -o addr show "$PHYS_IF" | awk '{print $4}' | head -n1 || true)
GATEWAY=$(ip route show default 2>/dev/null | awk '/via/{print $3; exit}')

echo "[*] Captured config -> IP: ${IP_CIDR:-none}  Gateway: ${GATEWAY:-none}"

# --- 2. Tell NetworkManager to release the physical interface ----------
if command -v nmcli &>/dev/null; then
    nmcli device set "$PHYS_IF" managed no 2>/dev/null || true
fi

# --- 3. Build the bridge --------------------------------------------------
echo "[*] Creating $BRIDGE"
ip link add name "$BRIDGE" type bridge
ip link set "$BRIDGE" up

echo "[*] Flushing IP off $PHYS_IF and enslaving it to $BRIDGE"
ip addr flush dev "$PHYS_IF"
ip link set "$PHYS_IF" up
ip link set "$PHYS_IF" master "$BRIDGE"

# --- 4. Try DHCP on the bridge first --------------------------------------
echo "[*] Requesting DHCP lease on $BRIDGE (timeout ${TIMEOUT}s)"
GOT_DHCP=0
if command -v dhclient &>/dev/null; then
    timeout "$TIMEOUT" dhclient -v "$BRIDGE" && GOT_DHCP=1 || true
elif command -v dhcpcd &>/dev/null; then
    timeout "$TIMEOUT" dhcpcd "$BRIDGE" && GOT_DHCP=1 || true
else
    echo "[!] No dhclient/dhcpcd found, skipping DHCP attempt"
fi

# --- 5. Fall back to the captured static config if DHCP failed ----------
if [[ "$GOT_DHCP" -ne 1 ]]; then
    if [[ -n "${IP_CIDR:-}" && -n "${GATEWAY:-}" ]]; then
        echo "[!] DHCP unavailable, restoring captured static config on $BRIDGE"
        ip addr add "$IP_CIDR" dev "$BRIDGE"
        ip route add default via "$GATEWAY" dev "$BRIDGE" 2>/dev/null || true
    else
        echo "[!] DHCP failed and no captured config to fall back on."
        echo "    Set an address manually, e.g.:"
        echo "    sudo ip addr add <your.ip.here>/24 dev $BRIDGE"
        echo "    sudo ip route add default via <gateway> dev $BRIDGE"
    fi
fi

echo "[*] Current state:"
ip -brief addr show "$PHYS_IF" "$BRIDGE"
ip route show default 2>/dev/null || true

echo "[*] Testing connectivity"
if ping -c2 -W2 1.1.1.1 &>/dev/null; then
    echo "[+] Network reachable via $BRIDGE"
else
    echo "[!] Still unreachable. Check 'ip route', DNS, and switch/cable config."
fi

# --- 6. QEMU bridge helper permissions ------------------------------------
mkdir -p /etc/qemu
touch /etc/qemu/bridge.conf
if ! grep -qx "allow $BRIDGE" /etc/qemu/bridge.conf; then
    echo "allow $BRIDGE" >> /etc/qemu/bridge.conf
    echo "[*] Added 'allow $BRIDGE' to /etc/qemu/bridge.conf"
fi

HELPER=$(command -v qemu-bridge-helper 2>/dev/null || echo /usr/lib/qemu/qemu-bridge-helper)
if [[ -x "$HELPER" ]]; then
    chmod u+s "$HELPER" 2>/dev/null || echo "[!] Could not set setuid bit on $HELPER (may need to run qemu as root or via sudo)"
else
    echo "[!] qemu-bridge-helper not found at expected path — check your qemu-utils package"
fi

echo
echo "=== Done. This is RUNTIME ONLY and will not survive a reboot. ==="
echo "To persist across reboots, add a netplan config like:"
cat <<EOF

  # /etc/netplan/99-qemu-bridge.yaml
  network:
    version: 2
    ethernets:
      $PHYS_IF:
        dhcp4: no
    bridges:
      $BRIDGE:
        interfaces: [$PHYS_IF]
        dhcp4: yes

  # then: sudo netplan apply

EOF
echo "Try now: ./vm.sh boot ubuntu-server"
