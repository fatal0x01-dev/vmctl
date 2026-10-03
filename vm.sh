#!/bin/bash

set -e

BASE_VM_DIR="/mnt/storage02/VM"
ISO_DIR="/mnt/ISO"
FW_DIR="/usr/share/OVMF"

OVMF_CODE="$FW_DIR/OVMF_CODE_4M.fd"
OVMF_VARS_TEMPLATE="$FW_DIR/OVMF_VARS_4M.fd"

# --------------------------------------------------
# Defaults (used when vm.conf lacks a key, so old
# configs keep working)
# --------------------------------------------------

set_defaults() {
    RAM="4G"
    CPU="2"
    DISK=""
    ISO=""
    ADDITIONAL_ISO=""

    NET="user"                 # user | bridge | tap | none
    BRIDGE="br0"               # for NET=bridge
    TAP="tap0"                 # for NET=tap
    NIC="virtio-net-pci"       # virtio-net-pci | e1000 | e1000e | rtl8139 | vmxnet3 ...
    MAC=""                     # empty = QEMU picks one
    HOSTFWD=""                 # user-mode only, e.g. tcp::2222-:22,tcp::8080-:80

    GPU="virtio-vga-gl"        # virtio-vga-gl | virtio-vga | qxl-vga | VGA | none
    DISPLAY_TYPE="gtk-gl"      # gtk-gl | gtk | sdl | vnc | none
    VNC_DISPLAY="0"            # for DISPLAY_TYPE=vnc (port 5900+N)

    # tag:hostpath:security_model  (multiple separated by ';')
    SHARES="hostshare:/mnt/storage01/shared:none;hosttools:/mnt/storage01/tools:passthrough"
}

# --------------------------------------------------
# Helpers
# --------------------------------------------------

normalize_ram() {
    local input="${1,,}"

    if [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "${input}G"
    elif [[ "$input" =~ ^[0-9]+[gm]$ ]]; then
        echo "${input^^}"
    else
        echo "[-] Invalid RAM value: $1" >&2
        exit 1
    fi
}

require_fzf() {
    command -v fzf >/dev/null 2>&1 || {
        echo "[-] fzf is required"
        echo "    sudo apt install fzf"
        exit 1
    }
}

vm_exists() {
    [[ -d "$BASE_VM_DIR/$1" ]]
}

random_mac() {
    # QEMU's OUI (52:54:00) + 3 random bytes
    printf '52:54:00:%02x:%02x:%02x\n' \
        $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256))
}

SHARES_OVERRIDDEN=0
SHIFT_N=0

# Parses ONE option out of "$@" and sets SHIFT_N to the number of
# args consumed (0 = not a known option). Shared by create/set/boot.
parse_common_opt() {
    SHIFT_N=0

    case "$1" in
        --ram)      RAM=$(normalize_ram "$2");  SHIFT_N=2 ;;
        --cpu)      CPU="$2";                   SHIFT_N=2 ;;
        --iso)      ISO="$2";                   SHIFT_N=2 ;;
        --no-iso)   ISO="";                     SHIFT_N=1 ;;
        --additional-iso)    ADDITIONAL_ISO="$2"; SHIFT_N=2 ;;
        --no-additional-iso) ADDITIONAL_ISO="";   SHIFT_N=1 ;;
        --net)      NET="$2";                   SHIFT_N=2 ;;
        --bridge)   BRIDGE="$2";                SHIFT_N=2 ;;
        --tap)      TAP="$2";                   SHIFT_N=2 ;;
        --nic)      NIC="$2";                   SHIFT_N=2 ;;
        --mac)      MAC="$2";                   SHIFT_N=2 ;;
        --hostfwd)  HOSTFWD="$2";               SHIFT_N=2 ;;
        --gpu)      GPU="$2";                   SHIFT_N=2 ;;
        --display)  DISPLAY_TYPE="$2";          SHIFT_N=2 ;;
        --vnc)      VNC_DISPLAY="$2";           SHIFT_N=2 ;;
        --no-share)
            SHARES=""; SHARES_OVERRIDDEN=1;     SHIFT_N=1 ;;
        --share)
            # first --share replaces the defaults, later ones append
            if [[ $SHARES_OVERRIDDEN -eq 0 ]]; then
                SHARES="$2"; SHARES_OVERRIDDEN=1
            else
                SHARES="${SHARES:+$SHARES;}$2"
            fi
            SHIFT_N=2 ;;
    esac

    if [[ $SHIFT_N -eq 2 && -z "${2+x}" ]]; then
        echo "[-] Missing value for $1"
        exit 1
    fi
}

validate_config() {
    case "$NET" in
        user|bridge|tap|none) ;;
        *) echo "[-] Invalid --net '$NET' (user|bridge|tap|none)"; exit 1 ;;
    esac
    case "$DISPLAY_TYPE" in
        gtk-gl|gtk|sdl|vnc|none) ;;
        *) echo "[-] Invalid --display '$DISPLAY_TYPE' (gtk-gl|gtk|sdl|vnc|none)"; exit 1 ;;
    esac
}

write_conf() {
    local conf="$1"
    {
        echo "RAM=$(printf %q "$RAM")"
        echo "CPU=$(printf %q "$CPU")"
        echo "DISK=$(printf %q "$DISK")"
        echo "ISO=$(printf %q "$ISO")"
        echo "ADDITIONAL_ISO=$(printf %q "$ADDITIONAL_ISO")"
        echo "# NET selects the active backend; only its matching setting is used."
        echo "NET=$(printf %q "$NET")  # active backend"
        if [[ "$NET" == "bridge" ]]; then
            echo "BRIDGE=$(printf %q "$BRIDGE")  # active"
        else
            echo "BRIDGE=$(printf %q "$BRIDGE")  # inactive unless NET=bridge"
        fi
        if [[ "$NET" == "tap" ]]; then
            echo "TAP=$(printf %q "$TAP")  # active"
        else
            echo "TAP=$(printf %q "$TAP")  # inactive unless NET=tap"
        fi
        echo "NIC=$(printf %q "$NIC")"
        echo "MAC=$(printf %q "$MAC")"
        if [[ "$NET" == "user" ]]; then
            echo "HOSTFWD=$(printf %q "$HOSTFWD")  # active"
        else
            echo "HOSTFWD=$(printf %q "$HOSTFWD")  # inactive unless NET=user"
        fi
        echo "GPU=$(printf %q "$GPU")"
        echo "DISPLAY_TYPE=$(printf %q "$DISPLAY_TYPE")"
        echo "VNC_DISPLAY=$(printf %q "$VNC_DISPLAY")"
        echo "SHARES=$(printf %q "$SHARES")"
    } > "$conf"
}

# --------------------------------------------------
# vm init
# --------------------------------------------------

init_vm() {

    local NAME="$1"
    local SIZE="$2"

    if [[ -z "$NAME" || -z "$SIZE" ]]; then
        echo "Usage:"
        echo "  vm init <name> <size>"
        echo
        echo "Example:"
        echo "  vm init ubuntu-server 40G"
        exit 1
    fi

    VM_DIR="$BASE_VM_DIR/$NAME"

    if vm_exists "$NAME"; then
        echo "[-] VM already exists"
        exit 1
    fi

    mkdir -p "$VM_DIR"

    echo "[*] Creating base disk..."

    qemu-img create \
        -f qcow2 \
        "$VM_DIR/$NAME.img" \
        "$SIZE"

    echo "[+] VM initialized"
}

# --------------------------------------------------
# vm create
# --------------------------------------------------

create_vm() {

    local NAME=""

    set_defaults
    RAM=""; CPU=""; ISO=""

    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--name" ]]; then
            NAME="$2"
            shift 2
            continue
        fi

        parse_common_opt "$@"
        if [[ $SHIFT_N -eq 0 ]]; then
            echo "Unknown argument: $1"
            exit 1
        fi
        shift "$SHIFT_N"
    done

    [[ -z "$NAME" ]] && { echo "Missing --name"; exit 1; }
    [[ -z "$RAM" ]]  && { echo "Missing --ram"; exit 1; }
    [[ -z "$CPU" ]]  && { echo "Missing --cpu"; exit 1; }
    [[ -z "$ISO" ]]  && { echo "Missing --iso"; exit 1; }

    validate_config

    VM_DIR="$BASE_VM_DIR/$NAME"
    BASE_DISK="$VM_DIR/$NAME.img"
    OVERLAY="$VM_DIR/$NAME.qcow2"
    ISO_PATH="$ISO_DIR/$ISO"

    [[ ! -f "$BASE_DISK" ]] && {
        echo "[-] Base disk not found:"
        echo "    $BASE_DISK"
        exit 1
    }

    [[ ! -f "$ISO_PATH" ]] && {
        echo "[-] ISO not found:"
        echo "    $ISO_PATH"
        exit 1
    }

    if [[ ! -f "$OVERLAY" ]]; then
        echo "[*] Creating overlay..."
        qemu-img create \
            -f qcow2 \
            -b "$BASE_DISK" \
            -F qcow2 \
            "$OVERLAY"
    fi

    # Stable MAC per VM (important for bridge/DHCP reservations)
    [[ -z "$MAC" ]] && MAC=$(random_mac)

    DISK="$NAME.qcow2"
    write_conf "$VM_DIR/vm.conf"

    echo "[+] VM configured"
}

# --------------------------------------------------
# vm set  (persistently change settings)
# --------------------------------------------------

set_vm() {

    local NAME="$1"
    shift || true

    [[ -z "$NAME" ]] && {
        echo "Usage:"
        echo "  vm set NAME [--net user|bridge|tap|none] [--bridge br0] [--nic e1000]"
        echo "              [--gpu ...] [--display ...] [--ram 8] [--cpu 4] ..."
        exit 1
    }

    local CONF="$BASE_VM_DIR/$NAME/vm.conf"
    [[ ! -f "$CONF" ]] && { echo "[-] Missing vm.conf"; exit 1; }

    set_defaults
    source "$CONF"

    while [[ $# -gt 0 ]]; do
        parse_common_opt "$@"
        if [[ $SHIFT_N -eq 0 ]]; then
            echo "Unknown argument: $1"
            exit 1
        fi
        shift "$SHIFT_N"
    done

    validate_config
    [[ -z "$MAC" ]] && MAC=$(random_mac)
    write_conf "$CONF"

    echo "[+] Updated $NAME"
}

# --------------------------------------------------
# vm show
# --------------------------------------------------

show_vm() {
    local CONF="$BASE_VM_DIR/$1/vm.conf"
    [[ ! -f "$CONF" ]] && { echo "[-] Missing vm.conf"; exit 1; }
    echo
    echo "[$1]"
    cat "$CONF"
    echo
}

# --------------------------------------------------
# vm list
# --------------------------------------------------

list_vms() {

    echo
    echo "Available VMs"
    echo "============="

    for d in "$BASE_VM_DIR"/*; do
        [[ -d "$d" ]] || continue

        VM_NAME=$(basename "$d")

        if [[ -f "$d/vm.conf" ]]; then
            echo "  $VM_NAME"
        fi
    done

    echo
}

# --------------------------------------------------
# vm boot
# --------------------------------------------------

boot_vm() {

    local NAME=""

    if [[ $# -gt 0 && "$1" != --* ]]; then
        NAME="$1"
        shift
    fi

    if [[ -z "$NAME" ]]; then

        require_fzf

        NAME=$(
            find "$BASE_VM_DIR" \
                -mindepth 1 \
                -maxdepth 1 \
                -type d \
            | xargs -n1 basename \
            | sort \
            | fzf \
                --height=40% \
                --border \
                --prompt="Boot VM > "
        )
    fi

    [[ -z "$NAME" ]] && exit 0

    VM_DIR="$BASE_VM_DIR/$NAME"
    CONF="$VM_DIR/vm.conf"

    [[ ! -f "$CONF" ]] && {
        echo "[-] Missing vm.conf"
        exit 1
    }

    set_defaults
    source "$CONF"

    # Temporary overrides (not saved)
    while [[ $# -gt 0 ]]; do
        parse_common_opt "$@"
        if [[ $SHIFT_N -eq 0 ]]; then
            echo "[!] Ignoring unknown argument: $1"
            shift
        else
            shift "$SHIFT_N"
        fi
    done

    validate_config

    DISK_PATH="$VM_DIR/$DISK"

    [[ ! -f "$DISK_PATH" ]] && {
        echo "[-] Disk not found:"
        echo "    $DISK_PATH"
        exit 1
    }

    # Per-VM UEFI variable store (so VMs don't share/overwrite NVRAM)
    VARS_FILE="$VM_DIR/OVMF_VARS.fd"
    [[ -f "$VARS_FILE" ]] || cp "$OVMF_VARS_TEMPLATE" "$VARS_FILE"

    local ARGS=(
        -enable-kvm
        -m "$RAM"
        -smp "$CPU"
        -cpu host
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
        -drive "if=pflash,format=raw,file=$VARS_FILE"
        -drive "file=$DISK_PATH,if=virtio,format=qcow2"
    )

    # ISO
    if [[ -n "$ISO" && -f "$ISO_DIR/$ISO" ]]; then
        ARGS+=(-cdrom "$ISO_DIR/$ISO")
    fi

    # Optional second CD-ROM image; use the configured path as-is.
    if [[ -n "$ADDITIONAL_ISO" ]]; then
        [[ -f "$ADDITIONAL_ISO" ]] || {
            echo "[-] Additional ISO not found:"
            echo "    $ADDITIONAL_ISO"
            exit 1
        }
        ARGS+=(-drive "file=$ADDITIONAL_ISO,media=cdrom,index=1")
    fi

    # Network
    local NIC_DEV="$NIC,netdev=n1"
    [[ -n "$MAC" ]] && NIC_DEV+=",mac=$MAC"

    case "$NET" in
        user)
            local NETDEV="user,id=n1"
            [[ -n "$HOSTFWD" ]] && NETDEV+=",hostfwd=${HOSTFWD//,/,hostfwd=}"
            ARGS+=(-netdev "$NETDEV" -device "$NIC_DEV")
            ;;
        bridge)
            # needs qemu-bridge-helper + "allow $BRIDGE" in /etc/qemu/bridge.conf
            ARGS+=(-netdev "bridge,id=n1,br=$BRIDGE" -device "$NIC_DEV")
            ;;
        tap)
            ARGS+=(-netdev "tap,id=n1,ifname=$TAP,script=no,downscript=no" -device "$NIC_DEV")
            ;;
        none)
            ARGS+=(-nic none)
            ;;
    esac

    # Display + GPU
    local GPU_DEV="$GPU"
    if [[ "$DISPLAY_TYPE" != "gtk-gl" && "$GPU_DEV" == *-gl ]]; then
        # GL GPU needs a GL display; fall back to the non-GL variant
        GPU_DEV="${GPU_DEV%-gl}"
        echo "[!] Display '$DISPLAY_TYPE' has no GL, using GPU '$GPU_DEV'"
    fi

    [[ "$GPU_DEV" != "none" ]] && ARGS+=(-device "$GPU_DEV")

    case "$DISPLAY_TYPE" in
        gtk-gl) ARGS+=(-display "gtk,gl=on,zoom-to-fit=on") ;;
        gtk)    ARGS+=(-display "gtk,zoom-to-fit=on") ;;
        sdl)    ARGS+=(-display sdl) ;;
        vnc)    ARGS+=(-display none -vnc ":$VNC_DISPLAY") ;;
        none)   ARGS+=(-display none) ;;
    esac

    # Shared folders (9p)
    if [[ -n "$SHARES" ]]; then
        local i=0 entry tag path sec
        IFS=';' read -ra SHARE_LIST <<< "$SHARES"
        for entry in "${SHARE_LIST[@]}"; do
            [[ -z "$entry" ]] && continue
            IFS=':' read -r tag path sec <<< "$entry"
            sec="${sec:-none}"
            if [[ ! -d "$path" ]]; then
                echo "[!] Share path missing, skipping: $path"
                continue
            fi
            ARGS+=(
                -fsdev "local,id=fsdev$i,path=$path,security_model=$sec"
                -device "virtio-9p-pci,fsdev=fsdev$i,mount_tag=$tag"
            )
            i=$((i + 1))
        done
    fi

    echo
    echo "[*] Booting VM"
    echo "    Name    : $NAME"
    echo "    RAM     : $RAM"
    echo "    CPU     : $CPU"
    echo "    Network : $NET ($NIC${MAC:+, $MAC})"
    echo "    Display : $DISPLAY_TYPE / $GPU_DEV"
    echo

    exec qemu-system-x86_64 "${ARGS[@]}"
}

# --------------------------------------------------
# vm clone
# --------------------------------------------------

clone_vm() {

    local SRC="$1"
    local DST="$2"

    [[ -z "$SRC" || -z "$DST" ]] && {
        echo "Usage:"
        echo "  vm clone SRC DST"
        exit 1
    }

    SRC_DIR="$BASE_VM_DIR/$SRC"
    DST_DIR="$BASE_VM_DIR/$DST"

    [[ ! -d "$SRC_DIR" ]] && {
        echo "[-] Source VM not found"
        exit 1
    }

    vm_exists "$DST" && { echo "[-] Destination already exists"; exit 1; }

    cp -a "$SRC_DIR" "$DST_DIR"

    mv "$DST_DIR/$SRC.img" "$DST_DIR/$DST.img" 2>/dev/null || true
    mv "$DST_DIR/$SRC.qcow2" "$DST_DIR/$DST.qcow2" 2>/dev/null || true

    # Overlay still points at the source's base image; repoint it
    if [[ -f "$DST_DIR/$DST.qcow2" ]]; then
        qemu-img rebase -u -b "$DST_DIR/$DST.img" -F qcow2 "$DST_DIR/$DST.qcow2"
    fi

    sed -i "s/$SRC\.qcow2/$DST.qcow2/g" "$DST_DIR/vm.conf"

    # Give the clone its own MAC so bridged clones don't collide
    if grep -q '^MAC=' "$DST_DIR/vm.conf"; then
        sed -i "s/^MAC=.*/MAC=$(random_mac)/" "$DST_DIR/vm.conf"
    fi

    echo "[+] Cloned $SRC -> $DST"
}

# --------------------------------------------------
# vm delete
# --------------------------------------------------

delete_vm() {

    local NAME="$1"

    [[ -z "$NAME" ]] && {
        echo "Usage:"
        echo "  vm delete NAME"
        exit 1
    }

    VM_DIR="$BASE_VM_DIR/$NAME"

    [[ ! -d "$VM_DIR" ]] && {
        echo "[-] VM not found"
        exit 1
    }

    rm -rf "$VM_DIR"

    echo "[+] Deleted $NAME"
}

# --------------------------------------------------
# Router
# --------------------------------------------------

case "$1" in

    init)   shift; init_vm "$@" ;;
    create) shift; create_vm "$@" ;;
    set)    shift; set_vm "$@" ;;
    show)   shift; show_vm "$@" ;;
    list)   list_vms ;;
    boot)   shift; boot_vm "$@" ;;
    clone)  shift; clone_vm "$@" ;;
    delete) shift; delete_vm "$@" ;;

    *)
        cat <<EOF

vm - Mini Hypervisor CLI

Commands:

  vm init NAME SIZE                Create base disk
  vm create --name N --ram 4 --cpu 4 --iso x.iso [options]
                                   Create overlay + vm.conf
  vm set NAME [options]            Permanently change settings
  vm show NAME                     Print a VM's config
  vm boot [NAME] [options]         Boot (fzf picker if no name); options are
                                   temporary overrides
  vm list | vm clone SRC DST | vm delete NAME

Options (create / set / boot):

  --ram 8              --cpu 6
  --iso file.iso       --no-iso
  --additional-iso /path/to/tools.iso  --no-additional-iso
  --net user|bridge|tap|none
  --bridge br0         (with --net bridge)
  --tap tap0           (with --net tap)
  --nic virtio-net-pci|e1000|e1000e|rtl8139|vmxnet3
  --mac 52:54:00:..    --hostfwd tcp::2222-:22,tcp::8080-:80   (user net)
  --gpu virtio-vga-gl|virtio-vga|qxl-vga|VGA|none
  --display gtk-gl|gtk|sdl|vnc|none      --vnc 0   (VNC display number)
  --share tag:/host/path[:security]      (repeatable; first one replaces defaults)
  --no-share

Examples:

  vm set win11 --net bridge --bridge br0 --nic e1000e
  vm boot win11 --net user --hostfwd tcp::2222-:22
  vm boot ubuntu --display vnc --vnc 1 --gpu virtio-vga
  vm boot dev --share src:/home/me/src:mapped-xattr --share iso:/mnt/ISO:none

EOF
        ;;
esac