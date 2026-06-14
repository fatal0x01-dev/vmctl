#!/bin/bash

set -e

BASE_VM_DIR="/mnt/VMs"
ISO_DIR="/mnt/ISO"
FW_DIR="/usr/share/OVMF"

OVMF_CODE="$FW_DIR/OVMF_CODE_4M.fd"
OVMF_VARS="$FW_DIR/OVMF_VARS_4M.fd"

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
        echo "[-] Invalid RAM value: $1"
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
    local RAM=""
    local CPU=""
    local ISO_NAME=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                NAME="$2"
                shift 2
                ;;
            --ram)
                RAM="$2"
                shift 2
                ;;
            --cpu)
                CPU="$2"
                shift 2
                ;;
            --iso)
                ISO_NAME="$2"
                shift 2
                ;;
            *)
                echo "Unknown argument: $1"
                exit 1
                ;;
        esac
    done

    [[ -z "$NAME" ]] && { echo "Missing --name"; exit 1; }
    [[ -z "$RAM" ]] && { echo "Missing --ram"; exit 1; }
    [[ -z "$CPU" ]] && { echo "Missing --cpu"; exit 1; }
    [[ -z "$ISO_NAME" ]] && { echo "Missing --iso"; exit 1; }

    RAM=$(normalize_ram "$RAM")

    VM_DIR="$BASE_VM_DIR/$NAME"
    BASE_DISK="$VM_DIR/$NAME.img"
    OVERLAY="$VM_DIR/$NAME.qcow2"
    ISO_PATH="$ISO_DIR/$ISO_NAME"

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

    cat > "$VM_DIR/vm.conf" <<EOF
RAM=$RAM
CPU=$CPU
DISK=$NAME.qcow2
ISO=$ISO_NAME
EOF

    echo "[+] VM configured"
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

    local NAME="$1"

    shift || true

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

    source "$CONF"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ram)
                RAM=$(normalize_ram "$2")
                shift 2
                ;;
            --cpu)
                CPU="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    DISK_PATH="$VM_DIR/$DISK"

    [[ ! -f "$DISK_PATH" ]] && {
        echo "[-] Disk not found:"
        echo "    $DISK_PATH"
        exit 1
    }

    ISO_ARGS=""

    if [[ -n "$ISO" ]]; then

        ISO_PATH="$ISO_DIR/$ISO"

        if [[ -f "$ISO_PATH" ]]; then
            ISO_ARGS="-cdrom $ISO_PATH"
        fi
    fi

    echo
    echo "[*] Booting VM"
    echo "    Name : $NAME"
    echo "    RAM  : $RAM"
    echo "    CPU  : $CPU"
    echo

    exec qemu-system-x86_64 \
        -enable-kvm \
        -m "$RAM" \
        -smp "$CPU" \
        -cpu host \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$OVMF_VARS" \
        -drive file="$DISK_PATH",if=virtio,format=qcow2 \
        ${ISO_ARGS:+$ISO_ARGS} \
        -netdev bridge,id=n1,br=br0 \
        -device virtio-net-pci,netdev=n1 \
        -device virtio-vga-gl \
        -display gtk,gl=on,zoom-to-fit=on \
        -fsdev local,id=fsdev0,path=/mnt/storage01/shared,security_model=none \
        -device virtio-9p-pci,fsdev=fsdev0,mount_tag=hostshare \
        -fsdev local,id=fs_tools,path=/mnt/storage01/tools,security_model=passthrough \
        -device virtio-9p-pci,fsdev=fs_tools,mount_tag=hosttools
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

    cp -a "$SRC_DIR" "$DST_DIR"

    mv "$DST_DIR/$SRC.img" "$DST_DIR/$DST.img" 2>/dev/null || true
    mv "$DST_DIR/$SRC.qcow2" "$DST_DIR/$DST.qcow2" 2>/dev/null || true

    sed -i "s/$SRC\.qcow2/$DST.qcow2/g" "$DST_DIR/vm.conf"

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

    init)
        shift
        init_vm "$@"
        ;;

    create)
        shift
        create_vm "$@"
        ;;

    list)
        list_vms
        ;;

    boot)
        shift
        boot_vm "$@"
        ;;

    clone)
        shift
        clone_vm "$@"
        ;;

    delete)
        shift
        delete_vm "$@"
        ;;

    *)
        cat <<EOF

vm - Mini Hypervisor CLI

Commands:

  vm init NAME SIZE

      Create base disk

      Example:
      vm init ubuntu-server 40G

  vm create --name NAME --ram 4 --cpu 4 --iso ubuntu.iso

      Create overlay + vm.conf

  vm boot

      Interactive VM selector

  vm boot ubuntu-server

      Boot specific VM

  vm boot ubuntu-server --ram 8 --cpu 6

      Temporary overrides

  vm list

      Show all VMs

  vm clone SRC DST

      Clone a VM

  vm delete NAME

      Delete a VM

EOF
        ;;
esac
