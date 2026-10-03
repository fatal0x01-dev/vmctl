#!/usr/bin/env bash
# tapbridge.sh - set up / tear down a TAP + bridge adapter on Arch Linux
#
# Typical use: give VMs (QEMU/KVM, etc.) a TAP device attached to a bridge.
#
#   sudo ./tapbridge.sh setup                 # bridge your default-route NIC + tap0
#   sudo ./tapbridge.sh setup --isolated --nat  # host-only bridge with NAT to the internet
#   sudo ./tapbridge.sh status
#   sudo ./tapbridge.sh remove                # undo EVERYTHING setup did
#
# Backends (auto-detected): NetworkManager (nm), systemd-networkd (networkd),
# or plain iproute2 (ip, non-persistent, gone after reboot).

set -euo pipefail

STATE_DIR=/var/lib/tapbridge
NETD_DIR=/etc/systemd/network

# ---- defaults (override with options) --------------------------------------
BRIDGE=br0
TAP=tap0
UPLINK=""
TAP_USER="${SUDO_USER:-root}"
ADDR="192.168.100.1/24"
BACKEND=auto
ISOLATED=0
NAT=0
ASSUME_YES=0

# ---- restore info, persisted in the state file -----------------------------
NM_ORIG="" NM_ORIG_AUTO="" NETD_ENABLED="" NETD_ACTIVE=""
IP_FORWARD_PREV="" ADDRS="" GW=""

log() { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }
die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: sudo $0 <setup|remove|status> [options]

Options:
  -b, --bridge NAME     bridge name                  (default: $BRIDGE)
  -t, --tap NAME        tap device name              (default: $TAP)
  -i, --uplink IFACE    physical NIC to enslave      (default: NIC of default route)
  -u, --user USER       user allowed to open the tap (default: \$SUDO_USER or root)
      --isolated        no physical NIC; host-only bridge with a static address
  -a, --addr CIDR       bridge address in isolated mode (default: $ADDR)
      --nat             isolated mode only: masquerade bridge traffic out of the host
      --backend B       auto | nm | networkd | ip    (default: auto)
  -y, --yes             don't ask for confirmation
  -h, --help            show this help

'remove' undoes exactly what 'setup' did, using $STATE_DIR/<bridge>.state.
For 'remove'/'status' pass -b if you used a non-default bridge name.
EOF
}

need_root() { [[ $EUID -eq 0 ]] || die "must be run as root (use sudo)"; }

valid_if() {
  [[ $1 =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || die "invalid interface name: '$1'"
}

iface_exists() { [[ -d /sys/class/net/$1 ]]; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -b|--bridge)  BRIDGE=${2:?missing value for $1}; shift 2 ;;
      -t|--tap)     TAP=${2:?missing value for $1}; shift 2 ;;
      -i|--uplink)  UPLINK=${2:?missing value for $1}; shift 2 ;;
      -u|--user)    TAP_USER=${2:?missing value for $1}; shift 2 ;;
      -a|--addr)    ADDR=${2:?missing value for $1}; shift 2 ;;
      --backend)    BACKEND=${2:?missing value for $1}; shift 2 ;;
      --isolated)   ISOLATED=1; shift ;;
      --nat)        NAT=1; shift ;;
      -y|--yes)     ASSUME_YES=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      *)            die "unknown option: $1 (try --help)" ;;
    esac
  done
  STATE_FILE="$STATE_DIR/$BRIDGE.state"
}

save_state() {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  : >"$STATE_FILE"
  local v
  for v in BACKEND BRIDGE TAP UPLINK ISOLATED NAT NM_ORIG NM_ORIG_AUTO \
           NETD_ENABLED NETD_ACTIVE IP_FORWARD_PREV ADDRS GW; do
    printf '%s=%q\n' "$v" "${!v:-}" >>"$STATE_FILE"
  done
}

choose_backend() {
  if [[ $BACKEND == auto ]]; then
    if systemctl is-active --quiet NetworkManager; then BACKEND=nm; else BACKEND=networkd; fi
  fi
  case $BACKEND in
    nm)
      command -v nmcli >/dev/null || die "nmcli not found (pacman -S networkmanager)"
      systemctl is-active --quiet NetworkManager || die "NetworkManager is not running"
      ;;
    networkd)
      if systemctl is-active --quiet NetworkManager; then
        die "NetworkManager is running; use --backend nm (or stop it first)"
      fi
      if systemctl is-active --quiet dhcpcd || systemctl list-units --state=active 'dhcpcd@*' --no-legend | grep -q .; then
        warn "dhcpcd is active and may fight with systemd-networkd over $UPLINK"
      fi
      ;;
    ip)
      if systemctl is-active --quiet NetworkManager; then
        warn "NetworkManager is running and may interfere with a manual bridge"
      fi
      ;;
    *) die "unknown backend '$BACKEND' (auto|nm|networkd|ip)" ;;
  esac
}

# ============================== NAT (optional) ===============================
nat_ident() { echo "tapbridge_${BRIDGE//[^A-Za-z0-9_]/_}"; }

nat_setup() {
  command -v nft >/dev/null || die "nft not found (pacman -S nftables)"
  local id; id=$(nat_ident)
  IP_FORWARD_PREV=$(sysctl -n net.ipv4.ip_forward)
  save_state

  log "Enabling IPv4 forwarding"
  echo "net.ipv4.ip_forward = 1" >"/etc/sysctl.d/99-$id.conf"
  sysctl -q -w net.ipv4.ip_forward=1

  log "Installing NAT rules (service: $id.service)"
  cat >"/etc/$id.nft" <<NFT
table ip $id {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    iifname "$BRIDGE" oifname != "$BRIDGE" masquerade
  }
}
NFT
  cat >"/etc/systemd/system/$id.service" <<UNIT
[Unit]
Description=NAT for bridge $BRIDGE (tapbridge)
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nft -f /etc/$id.nft
ExecStop=/usr/bin/nft delete table ip $id

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now "$id.service"
}

nat_remove() {
  local id; id=$(nat_ident)
  if [[ -e /etc/systemd/system/$id.service ]]; then
    log "Removing NAT rules"
    systemctl disable --now "$id.service" 2>/dev/null || true
    nft delete table ip "$id" 2>/dev/null || true
    rm -f "/etc/systemd/system/$id.service" "/etc/$id.nft"
    systemctl daemon-reload
  fi
  if [[ -e /etc/sysctl.d/99-$id.conf ]]; then
    rm -f "/etc/sysctl.d/99-$id.conf"
    if [[ -n ${IP_FORWARD_PREV:-} ]]; then
      log "Restoring net.ipv4.ip_forward=$IP_FORWARD_PREV"
      sysctl -q -w "net.ipv4.ip_forward=$IP_FORWARD_PREV" || true
    fi
  fi
}

# ============================ backend: systemd-networkd ======================
networkd_setup() {
  local mac_line=""
  if [[ -n $UPLINK ]]; then
    mac_line="MACAddress=$(cat "/sys/class/net/$UPLINK/address")"
  fi

  log "Writing systemd-networkd config in $NETD_DIR"
  mkdir -p "$NETD_DIR"

  cat >"$NETD_DIR/10-$BRIDGE.netdev" <<EOF
[NetDev]
Name=$BRIDGE
Kind=bridge
$mac_line
EOF

  if [[ -n $UPLINK ]]; then
    cat >"$NETD_DIR/10-$BRIDGE.network" <<EOF
[Match]
Name=$BRIDGE

[Network]
DHCP=yes
EOF
    cat >"$NETD_DIR/10-$BRIDGE-uplink.network" <<EOF
[Match]
Name=$UPLINK

[Network]
Bridge=$BRIDGE
EOF
  else
    cat >"$NETD_DIR/10-$BRIDGE.network" <<EOF
[Match]
Name=$BRIDGE

[Network]
Address=$ADDR
ConfigureWithoutCarrier=yes
EOF
  fi

  cat >"$NETD_DIR/10-$TAP.netdev" <<EOF
[NetDev]
Name=$TAP
Kind=tap

[Tap]
User=$TAP_USER
EOF
  cat >"$NETD_DIR/10-$TAP.network" <<EOF
[Match]
Name=$TAP

[Network]
Bridge=$BRIDGE
EOF

  if [[ $NETD_ACTIVE == 1 ]]; then
    log "Reloading systemd-networkd"
    networkctl reload
  else
    log "Enabling and starting systemd-networkd"
    systemctl enable --now systemd-networkd
  fi
}

networkd_remove() {
  log "Removing systemd-networkd config"
  rm -f "$NETD_DIR/10-$BRIDGE.netdev" "$NETD_DIR/10-$BRIDGE.network" \
        "$NETD_DIR/10-$BRIDGE-uplink.network" \
        "$NETD_DIR/10-$TAP.netdev" "$NETD_DIR/10-$TAP.network"

  # networkd does not delete virtual devices when their .netdev disappears
  ip link del "$TAP" 2>/dev/null || true
  ip link del "$BRIDGE" 2>/dev/null || true

  if [[ ${NETD_ACTIVE:-0} == 1 ]]; then
    networkctl reload || true
    [[ -n ${UPLINK:-} ]] && networkctl reconfigure "$UPLINK" 2>/dev/null || true
  else
    if [[ ${NETD_ENABLED:-0} == 1 ]]; then
      systemctl stop systemd-networkd.service systemd-networkd.socket 2>/dev/null || true
    else
      log "Disabling systemd-networkd (it was not enabled before)"
      systemctl disable --now systemd-networkd.service systemd-networkd.socket 2>/dev/null || true
    fi
  fi
}

# ============================ backend: NetworkManager ========================
nm_setup() {
  local uid; uid=$(id -u "$TAP_USER")
  local c_br="tapbridge-$BRIDGE" c_up="tapbridge-$BRIDGE-uplink" c_tap="tapbridge-$BRIDGE-$TAP"

  log "Creating NetworkManager connections"
  if [[ -n $UPLINK ]]; then
    nmcli connection add type bridge ifname "$BRIDGE" con-name "$c_br" \
      bridge.stp no ipv4.method auto ipv6.method auto \
      bridge.mac-address "$(cat "/sys/class/net/$UPLINK/address")"
    nmcli connection add type bridge-slave ifname "$UPLINK" master "$BRIDGE" con-name "$c_up"
  else
    nmcli connection add type bridge ifname "$BRIDGE" con-name "$c_br" \
      bridge.stp no ipv4.method manual ipv4.addresses "$ADDR" ipv6.method disabled
  fi
  nmcli connection add type tun mode tap owner "$uid" ifname "$TAP" \
    master "$BRIDGE" slave-type bridge con-name "$c_tap"

  log "Activating (a short network blip on $UPLINK is expected)"
  if [[ -n $UPLINK && -n $NM_ORIG ]]; then
    nmcli connection modify "$NM_ORIG" connection.autoconnect no
  fi
  nmcli connection up "$c_br"
  [[ -n $UPLINK ]] && nmcli connection up "$c_up"
  nmcli connection up "$c_tap" || warn "tap connection did not activate yet (it will once the bridge is up)"
}

nm_remove() {
  log "Removing NetworkManager connections"
  local c
  for c in "tapbridge-$BRIDGE-$TAP" "tapbridge-$BRIDGE-uplink" "tapbridge-$BRIDGE"; do
    nmcli connection delete "$c" 2>/dev/null || true
  done
  ip link del "$TAP" 2>/dev/null || true
  ip link del "$BRIDGE" 2>/dev/null || true

  if [[ -n ${NM_ORIG:-} ]]; then
    log "Restoring original connection '$NM_ORIG'"
    nmcli connection modify "$NM_ORIG" connection.autoconnect "${NM_ORIG_AUTO:-yes}" 2>/dev/null || true
    nmcli connection up "$NM_ORIG" 2>/dev/null || warn "could not re-activate '$NM_ORIG'"
  fi
}

# ============================ backend: plain iproute2 ========================
ip_setup() {
  log "Creating bridge and tap with iproute2 (not persistent across reboots)"
  ip link add name "$BRIDGE" type bridge
  [[ -n $UPLINK ]] && ip link set "$BRIDGE" address "$(cat "/sys/class/net/$UPLINK/address")"
  ip tuntap add dev "$TAP" mode tap user "$TAP_USER"
  ip link set "$TAP" master "$BRIDGE"
  ip link set "$TAP" up
  ip link set "$BRIDGE" up

  if [[ -n $UPLINK ]]; then
    ip addr flush dev "$UPLINK"
    ip link set "$UPLINK" master "$BRIDGE"
    local a
    for a in $ADDRS; do ip addr add "$a" dev "$BRIDGE"; done
    [[ -n $GW ]] && ip route replace default via "$GW" dev "$BRIDGE"
  else
    ip addr add "$ADDR" dev "$BRIDGE"
  fi
}

ip_remove() {
  log "Removing bridge and tap"
  [[ -n ${UPLINK:-} ]] && ip link set "$UPLINK" nomaster 2>/dev/null || true
  ip link del "$TAP" 2>/dev/null || true
  ip link del "$BRIDGE" 2>/dev/null || true
  if [[ -n ${UPLINK:-} ]]; then
    ip link set "$UPLINK" up 2>/dev/null || true
    local a
    for a in ${ADDRS:-}; do ip addr add "$a" dev "$UPLINK" 2>/dev/null || true; done
    [[ -n ${GW:-} ]] && ip route replace default via "$GW" dev "$UPLINK" 2>/dev/null || true
  fi
}

# ================================ commands ===================================
cmd_setup() {
  need_root
  valid_if "$BRIDGE"; valid_if "$TAP"
  [[ $BRIDGE != "$TAP" ]] || die "bridge and tap names must differ"

  if [[ -e $STATE_FILE ]]; then
    die "'$BRIDGE' is already set up (state: $STATE_FILE). Run '$0 remove -b $BRIDGE' first."
  fi
  iface_exists "$BRIDGE" && die "interface '$BRIDGE' already exists"
  iface_exists "$TAP" && die "interface '$TAP' already exists"
  id "$TAP_USER" >/dev/null 2>&1 || die "user '$TAP_USER' does not exist"
  command -v ip >/dev/null || die "ip not found (pacman -S iproute2)"

  if (( NAT )) && (( ! ISOLATED )); then
    die "--nat only makes sense with --isolated"
  fi

  if (( ISOLATED )); then
    UPLINK=""
  else
    if [[ -z $UPLINK ]]; then
      UPLINK=$(ip -4 route show default | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
      [[ -n $UPLINK ]] || die "no default route found; pass -i IFACE or use --isolated"
    fi
    valid_if "$UPLINK"
    iface_exists "$UPLINK" || die "uplink '$UPLINK' does not exist"
    [[ -d /sys/class/net/$UPLINK/wireless ]] && \
      die "'$UPLINK' is wireless; Wi-Fi clients usually can't be bridged. Use --isolated --nat instead."
  fi

  choose_backend

  echo "About to configure:"
  echo "  backend : $BACKEND"
  echo "  bridge  : $BRIDGE"
  echo "  tap     : $TAP (owner: $TAP_USER)"
  if [[ -n $UPLINK ]]; then
    echo "  uplink  : $UPLINK  (will be moved into the bridge; the bridge takes over its IP)"
  else
    echo "  mode    : isolated, bridge address $ADDR$( ((NAT)) && echo ', NAT on')"
  fi
  if [[ -n $UPLINK && -n ${SSH_CONNECTION:-} ]]; then
    warn "you appear to be connected over SSH; the connection may drop briefly or permanently"
  fi
  if (( ! ASSUME_YES )); then
    read -r -p "Proceed? [y/N] " ans
    [[ $ans =~ ^[Yy]$ ]] || die "aborted"
  fi

  # ---- collect information needed for a clean rollback ----
  if [[ $BACKEND == networkd ]]; then
    NETD_ENABLED=0; NETD_ACTIVE=0
    systemctl is-enabled --quiet systemd-networkd 2>/dev/null && NETD_ENABLED=1
    systemctl is-active --quiet systemd-networkd 2>/dev/null && NETD_ACTIVE=1
  fi
  if [[ $BACKEND == nm && -n $UPLINK ]]; then
    NM_ORIG=$(nmcli -g GENERAL.CONNECTION device show "$UPLINK" 2>/dev/null || true)
    [[ $NM_ORIG == "--" ]] && NM_ORIG=""
    if [[ -n $NM_ORIG ]]; then
      NM_ORIG_AUTO=$(nmcli -g connection.autoconnect connection show "$NM_ORIG" 2>/dev/null || echo yes)
    fi
  fi
  if [[ $BACKEND == ip && -n $UPLINK ]]; then
    ADDRS=$(ip -4 -o addr show dev "$UPLINK" scope global | awk '{print $4}' | tr '\n' ' ')
    GW=$(ip -4 route show default dev "$UPLINK" | awk '{for(i=1;i<NF;i++) if($i=="via"){print $(i+1); exit}}')
  fi

  # Save state BEFORE changing anything so 'remove' also cleans up a partial setup
  save_state
  trap 'warn "setup failed part-way; run: sudo $0 remove -b $BRIDGE   to roll back"' ERR

  case $BACKEND in
    nm)       nm_setup ;;
    networkd) networkd_setup ;;
    ip)       ip_setup ;;
  esac

  (( NAT )) && nat_setup
  trap - ERR

  log "Done."
  cat <<EOF

  Bridge : $BRIDGE
  Tap    : $TAP  (usable by $TAP_USER)

  Example QEMU usage:
    qemu-system-x86_64 -enable-kvm -m 2G \\
      -netdev tap,id=n0,ifname=$TAP,script=no,downscript=no \\
      -device virtio-net-pci,netdev=n0 ...

  Undo everything with:  sudo $0 remove -b $BRIDGE
EOF
}

cmd_remove() {
  need_root
  valid_if "$BRIDGE"
  [[ -e $STATE_FILE ]] || die "no state file for '$BRIDGE' ($STATE_FILE); nothing to remove"

  # shellcheck disable=SC1090
  source "$STATE_FILE"

  # Best effort from here on: keep going even if individual steps fail
  set +e
  log "Removing '$BRIDGE' / '$TAP' (backend: $BACKEND)"
  (( ${NAT:-0} )) && nat_remove
  case $BACKEND in
    nm)       nm_remove ;;
    networkd) networkd_remove ;;
    ip)       ip_remove ;;
  esac
  rm -f "$STATE_FILE"
  rmdir "$STATE_DIR" 2>/dev/null
  log "All changes removed."
  if [[ $BACKEND != nm && -n ${UPLINK:-} ]]; then
    echo "Note: if '$UPLINK' was managed by another tool (dhcpcd, iwd, ...), restart it to regain an address."
  fi
}

cmd_status() {
  echo "State file: $STATE_FILE"
  if [[ -e $STATE_FILE ]]; then
    sed 's/^/  /' "$STATE_FILE"
  else
    echo "  (none - not set up by this script)"
  fi
  echo
  if iface_exists "$BRIDGE"; then
    ip -br addr show "$BRIDGE"
    echo "Members:"
    ip -br link show master "$BRIDGE" | sed 's/^/  /'
  else
    echo "Bridge '$BRIDGE' does not exist."
  fi
}

main() {
  local cmd=${1:-}
  if [[ -z $cmd || $cmd == -h || $cmd == --help ]]; then usage; exit 0; fi
  shift
  parse_args "$@"
  case $cmd in
    setup)  cmd_setup ;;
    remove) cmd_remove ;;
    status) cmd_status ;;
    *)      usage; exit 1 ;;
  esac
}

main "$@"
