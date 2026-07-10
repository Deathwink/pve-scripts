#!/usr/bin/env bash
# DietPi VM installer for Proxmox VE
# Creates a DietPi Trixie VM following the LoxBerry Proxmox installation guide.
# Run this script on the Proxmox VE host as root.
#
# The script creates and starts the VM. After DietPi's first-boot setup,
# install LoxBerry from inside the VM using the official LoxBerry instructions.

set -Eeuo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

APP="LoxBerry"
DIETPI_BASE_URL="https://dietpi.com/downloads/images"
DIETPI_IMAGE="DietPi_VM-x86_64-Bookworm.img.xz"
DIETPI_URL="${DIETPI_BASE_URL}/${DIETPI_IMAGE}"
DIETPI_SHA_URL="${DIETPI_URL}.sha256"

TMP_DIR=""
VM_CREATED=0
VM_ID=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { printf "${CYAN}==>${RESET} %s\n" "$*"; }
success() { printf "${GREEN}[OK]${RESET} %s\n" "$*"; }
warn()    { printf "${YELLOW}[!]${RESET} %s\n" "$*"; }
die()     { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; exit 1; }

cleanup() {
  local exit_code=$?
  [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"

  if (( exit_code != 0 )) && (( VM_CREATED == 1 )) && [[ -n "${VM_ID:-}" ]]; then
    warn "Installation failed after VM ${VM_ID} was created."
    warn "The incomplete VM has not been deleted automatically."
  fi
}
trap cleanup EXIT

require_root() {
  [[ $EUID -eq 0 ]] || die "Run this script as root on the Proxmox VE host."
}

require_proxmox() {
  command -v pvesh >/dev/null 2>&1 || die "This does not appear to be a Proxmox VE host."
  command -v qm >/dev/null 2>&1 || die "The qm command is not available."
}

install_dependencies() {
  local missing=()
  for cmd in curl xz sha256sum awk sed grep; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if ((${#missing[@]})); then
    info "Installing required packages..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl xz-utils coreutils gawk grep sed
  fi

  if ! command -v whiptail >/dev/null 2>&1; then
    info "Installing whiptail..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail
  fi
}

next_vmid() {
  pvesh get /cluster/nextid 2>/dev/null
}

storage_choices() {
  # Return enabled storages which can hold VM disk images.
  pvesm status -content images 2>/dev/null |
    awk 'NR > 1 && $3 == "active" {print $1}'
}

choose_storage() {
  local items=()
  local storage

  while IFS= read -r storage; do
    [[ -n "$storage" ]] || continue
    items+=("$storage" "Available")
  done < <(storage_choices)

  ((${#items[@]})) || die "No active Proxmox storage with 'Disk image' content is available."

  if ((${#items[@]} == 2)); then
    printf '%s' "${items[0]}"
    return
  fi

  whiptail \
    --title "$APP - Storage" \
    --menu "Select the storage for the VM disk:" \
    18 70 10 \
    "${items[@]}" \
    3>&1 1>&2 2>&3
}

choose_bridge() {
  local bridges=()
  local bridge

  while IFS= read -r bridge; do
    [[ -n "$bridge" ]] && bridges+=("$bridge" "Linux bridge")
  done < <(
    {
      ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E '^vmbr[0-9]+$' || true
      grep -hE '^iface vmbr[0-9]+ inet' /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null |
        awk '{print $2}' || true
    } | sort -u
  )

  ((${#bridges[@]})) || die "No Proxmox network bridge (vmbrX) was found."

  if printf '%s\n' "${bridges[@]}" | grep -qx "vmbr0"; then
    printf 'vmbr0'
    return
  fi

  if ((${#bridges[@]} == 2)); then
    printf '%s' "${bridges[0]}"
    return
  fi

  whiptail \
    --title "$APP - Network" \
    --menu "Select the network bridge:" \
    18 70 10 \
    "${bridges[@]}" \
    3>&1 1>&2 2>&3
}

validate_integer() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 ))
}

prompt_settings() {
  local default_id
  default_id="$(next_vmid)"

  VM_ID="$(whiptail --title "$APP - VM ID" \
    --inputbox "Enter the VM ID:" 10 60 "$default_id" \
    3>&1 1>&2 2>&3)" || exit 1
  validate_integer "$VM_ID" || die "Invalid VM ID."
  qm status "$VM_ID" >/dev/null 2>&1 && die "VM ID ${VM_ID} already exists."

  VM_NAME="$(whiptail --title "$APP - Name" \
    --inputbox "Enter the VM name:" 10 60 "loxberry" \
    3>&1 1>&2 2>&3)" || exit 1
  [[ "$VM_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] ||
    die "The VM name contains unsupported characters."

  CORES="$(whiptail --title "$APP - CPU" \
    --inputbox "Number of CPU cores:" 10 60 "2" \
    3>&1 1>&2 2>&3)" || exit 1
  validate_integer "$CORES" || die "Invalid CPU core count."

  MEMORY="$(whiptail --title "$APP - Memory" \
    --inputbox "Memory in MiB (2048 recommended):" 10 60 "2048" \
    3>&1 1>&2 2>&3)" || exit 1
  validate_integer "$MEMORY" || die "Invalid memory size."

  DISK_SIZE="$(whiptail --title "$APP - Disk" \
    --inputbox "Final disk size in GiB:" 10 60 "16" \
    3>&1 1>&2 2>&3)" || exit 1
  validate_integer "$DISK_SIZE" || die "Invalid disk size."

  STORAGE="$(choose_storage)" || exit 1
  BRIDGE="$(choose_bridge)" || exit 1

  if whiptail --title "$APP - Autostart" \
    --yesno "Start the VM automatically when the Proxmox host boots?" 10 70; then
    ONBOOT=1
  else
    ONBOOT=0
  fi

  whiptail --title "$APP - Confirm" --yesno \
"VM ID:       $VM_ID
Name:        $VM_NAME
CPU cores:   $CORES
Memory:      ${MEMORY} MiB
Disk:        ${DISK_SIZE} GiB
Storage:     $STORAGE
Bridge:      $BRIDGE
Autostart:   $ONBOOT

Create and start this VM?" 18 72 || exit 0
}

download_image() {
  TMP_DIR="$(mktemp -d /tmp/loxberry-pve.XXXXXX)"
  cd "$TMP_DIR"

  info "Downloading DietPi Bookworm VM image..."
  curl --fail --location --progress-bar --output "$DIETPI_IMAGE" "$DIETPI_URL"

  info "Downloading SHA-256 checksum..."
  curl --fail --location --silent --show-error \
    --output "${DIETPI_IMAGE}.sha256" "$DIETPI_SHA_URL"

  info "Verifying image checksum..."
  # Official checksum files contain the hash and filename.
  sha256sum --check "${DIETPI_IMAGE}.sha256"
  success "DietPi image verified."

  info "Extracting image..."
  xz --decompress --keep "$DIETPI_IMAGE"
  RAW_IMAGE="${DIETPI_IMAGE%.xz}"
  [[ -s "$RAW_IMAGE" ]] || die "The extracted DietPi image was not found."
}

create_vm() {
  info "Creating Proxmox VM ${VM_ID}..."

  qm create "$VM_ID" \
    --name "$VM_NAME" \
    --description "LoxBerry VM based on the official DietPi Bookworm x86_64 image." \
    --ostype l26 \
    --machine q35 \
    --bios seabios \
    --cpu kvm64 \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --balloon 0 \
    --scsihw virtio-scsi-single \
    --net0 "virtio,bridge=${BRIDGE}" \
    --agent enabled=1 \
    --onboot "$ONBOOT" \
    --tablet 0 \
    --serial0 socket \
    --vga serial0

  VM_CREATED=1

  info "Importing the DietPi disk into storage '${STORAGE}'..."
  local import_output volume_id
  import_output="$(qm importdisk "$VM_ID" "$RAW_IMAGE" "$STORAGE" 2>&1)"
  printf '%s\n' "$import_output"

  volume_id="$(
    printf '%s\n' "$import_output" |
      sed -n "s/.*successfully imported disk '\([^']*\)'.*/\1/p" |
      tail -n1
  )"

  if [[ -z "$volume_id" ]]; then
    volume_id="$(
      qm config "$VM_ID" |
        sed -n 's/^unused[0-9]\+: \([^,[:space:]]*\).*/\1/p' |
        tail -n1
    )"
  fi

  [[ -n "$volume_id" ]] || die "Unable to determine the imported Proxmox volume ID."

  qm set "$VM_ID" --scsi0 "${volume_id},discard=on,ssd=1"
  qm set "$VM_ID" --boot "order=scsi0" --bootdisk scsi0

  local current_bytes target_bytes add_bytes
  current_bytes="$(qemu-img info --output=json "$RAW_IMAGE" | grep -o '"virtual-size":[[:space:]]*[0-9]*' | grep -o '[0-9]*' | head -n1 || true)"
  target_bytes=$((DISK_SIZE * 1024 * 1024 * 1024))

  if [[ -n "$current_bytes" ]] && (( target_bytes > current_bytes )); then
    add_bytes=$((target_bytes - current_bytes))
    info "Growing virtual disk to approximately ${DISK_SIZE} GiB..."
    qm resize "$VM_ID" scsi0 "+${add_bytes}B"
  elif [[ -n "$current_bytes" ]] && (( target_bytes < current_bytes )); then
    warn "Requested disk size is smaller than the image; keeping the original image size."
  fi

  success "VM ${VM_ID} created."
}

start_vm() {
  info "Starting VM ${VM_ID}..."
  qm start "$VM_ID"
  success "VM ${VM_ID} started."
}

show_result() {
  local node
  node="$(hostname)"

  cat <<EOF

${GREEN}${BOLD}LoxBerry VM created successfully.${RESET}

VM ID:       ${VM_ID}
VM name:     ${VM_NAME}
Proxmox node:${node}
Network:     DHCP via ${BRIDGE}

Next steps:
1. Open the VM console in Proxmox and complete DietPi's first-boot setup.
2. Log in to DietPi and complete its updates/configuration.
3. Continue with the official LoxBerry installation procedure inside the VM.
4. After installation, open LoxBerry in a browser using the VM's IP address.

Useful commands on the Proxmox host:
  qm terminal ${VM_ID}
  qm status ${VM_ID}
  qm guest cmd ${VM_ID} network-get-interfaces

Note: The QEMU Guest Agent becomes available only after it is installed
and running inside the guest.
EOF
}

main() {
  clear
  printf "${BOLD}LoxBerry VM installer for Proxmox VE${RESET}\n\n"

  require_root
  require_proxmox
  install_dependencies

  whiptail --title "$APP installer" --msgbox \
"This script creates a Proxmox VM from the current DietPi Bookworm x86_64 image.

It follows the VM layout recommended by the LoxBerry Proxmox guide:
- Linux VM
- VirtIO SCSI disk
- VirtIO network adapter
- bridged LAN access
- at least 1 GiB RAM

LoxBerry itself is installed after DietPi's first-boot setup." 18 74

  prompt_settings
  download_image
  create_vm
  start_vm
  show_result
}

main "$@"
