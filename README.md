# vmctl

A lightweight QEMU/KVM virtual machine manager for lab environments.

`vmctl` provides a simple command-line interface for creating, cloning, configuring, and launching QEMU virtual machines using qcow2 backing images and overlays.

It is not a hypervisor. QEMU/KVM provides the virtualization layer; `vmctl` acts as a management wrapper that standardizes VM creation and boot workflows.

## Features

* Base image and overlay workflow
* Per-VM configuration files
* UEFI boot via OVMF
* QEMU/KVM acceleration
* VM cloning
* Interactive VM selection with `fzf`
* Temporary CPU and RAM overrides at boot
* Bridged networking support
* Shared host directories via VirtIO 9P

## VM Layout

Each VM resides in its own directory:

```text
windows-lab/
└── target-vm/
    ├── target-vm.img
    ├── target-vm.qcow2
    └── vm.conf
```

### Base Disk

The `.img` file acts as the backing image.

### Overlay Disk

The `.qcow2` file is created as a qcow2 overlay using the backing image.

### Configuration

Each VM stores runtime configuration in `vm.conf`.

Example:

```bash
RAM=8G
CPU=4
DISK=target-vm.qcow2
ISO=windows11.iso
```

## Requirements

* QEMU
* KVM
* OVMF firmware
* fzf (optional but required for interactive VM selection)

Example installation on Debian/Ubuntu:

```bash
sudo apt install qemu-system-x86 qemu-utils ovmf fzf
```

## Workflow

### 1. Create a Base Disk

```bash
vm init windows11 80G
```

Creates:

```text
windows11/
└── windows11.img
```

### 2. Configure a VM

```bash
vm create \
    --name windows11 \
    --ram 8 \
    --cpu 4 \
    --iso Win11.iso
```

Creates:

```text
windows11/
├── windows11.img
├── windows11.qcow2
└── vm.conf
```

### 3. Boot a VM

Interactive selection:

```bash
vm boot
```

Boot a specific VM:

```bash
vm boot windows11
```

Temporary overrides:

```bash
vm boot windows11 --ram 16 --cpu 8
```

## Commands

### Initialize a VM

```bash
vm init NAME SIZE
```

Example:

```bash
vm init ubuntu-server 40G
```

### Create a VM Configuration

```bash
vm create --name NAME --ram RAM --cpu CPU --iso IMAGE.iso
```

Example:

```bash
vm create \
    --name ubuntu-server \
    --ram 8 \
    --cpu 4 \
    --iso ubuntu-24.04.iso
```

### List VMs

```bash
vm list
```

### Boot a VM

```bash
vm boot
```

or

```bash
vm boot NAME
```

### Clone a VM

```bash
vm clone SOURCE DESTINATION
```

Example:

```bash
vm clone win11-base win11-dev
```

### Delete a VM

```bash
vm delete NAME
```

## Networking

The default launch configuration uses bridged networking through:

```bash
br0
```

Ensure the bridge exists and is configured on the host system before launching VMs.

## Shared Directories

The default configuration exposes the following host paths to guests:

```text
/mnt/storage01/shared
/mnt/storage01/tools
```

These are presented via VirtIO 9P and can be mounted inside the guest.

## Intended Use

`vmctl` is designed for lab environments where virtual machines are frequently created, cloned, tested, and discarded.

Typical use cases include:

* Malware analysis labs
* Windows testing environments
* Development sandboxes
* Red team infrastructure
* Training environments
* Disposable research VMs

```
```
