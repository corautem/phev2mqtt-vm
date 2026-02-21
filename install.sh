#!/usr/bin/env bash
#
# phev2mqtt Proxmox VM Installer
# https://github.com/corautem/phev2mqtt-vm
#
# This script creates and configures a Debian 12 VM on Proxmox VE
# with USB WiFi passthrough for phev2mqtt gateway functionality.
#

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_VERSION="1.0.0"
REPO_RAW_BASE="https://raw.githubusercontent.com/corautem/phev2mqtt-vm/main"
ADAPTERS_URL="${REPO_RAW_BASE}/adapters.txt"
VM_SETUP_URL="${REPO_RAW_BASE}/vm-setup.sh"

# Debian 12 cloud image
DEBIAN_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
DEBIAN_IMAGE_CHECKSUM_URL="${DEBIAN_IMAGE_URL}.SHA512"

# VM defaults
VM_CORES=1
VM_MEMORY=1024  # MB
VM_DISK_SIZE="12G"
VM_OS_TYPE="l26"  # Linux 2.6+ kernel

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Global variables
MODE="Simple"
VMID=""
VM_NAME="phev2mqtt"
STORAGE=""
USB_DEVICE=""
USB_ID=""
USB_DRIVER=""
USB_NOTES=""
TEMP_DIR=""
CREATED_VMID=""

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
    fi
    
    # Clean up partially created VM on error
    if [[ -n "${CREATED_VMID:-}" ]]; then
        log_error "Installation failed. Cleaning up VM ${CREATED_VMID}..."
        qm destroy "${CREATED_VMID}" 2>/dev/null || true
    fi
}

trap cleanup EXIT

die() {
    log_error "$*"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (or with sudo)"
    fi
}

check_proxmox() {
    if ! command -v qm &>/dev/null; then
        die "This script must be run on a Proxmox VE host (qm command not found)"
    fi
}

check_dependencies() {
    local deps=(whiptail curl lsusb wget)
    local missing=()
    
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}"
    fi
}

check_snippets_storage() {
    # Check if local storage has snippets content type enabled
    if ! pvesm status --content snippets | grep -q "^local "; then
        die "Snippets must be enabled on local storage — the installer uses this to pass the VM setup script to the VM via cloud-init.

To fix this:
  Proxmox UI → Datacenter → Storage → local → Edit
  → Content → tick 'Snippets' → click OK

Then re-run the installer."
    fi
}

# ============================================================================
# Whiptail Dialog Functions
# ============================================================================

show_welcome() {
    whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "phev2mqtt Proxmox Installer v${SCRIPT_VERSION}" \
        --msgbox "This installer will create a Debian 12 VM configured as a phev2mqtt gateway for Mitsubishi Outlander PHEV vehicles.\n\nWhat will be installed:\n• Debian 12 minimal VM (1 vCPU, 1GB RAM, 12GB disk)\n• USB WiFi adapter passthrough\n• phev2mqtt binary (built from source)\n• Web UI for configuration and management\n\nAfter installation, configure WiFi and MQTT via the web interface.\n\nDocumentation: ${REPO_RAW_BASE}/README.md" \
        20 78
}

select_mode() {
    MODE=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "Installation Mode" \
        --menu "Select installation mode:" \
        12 60 2 \
        "Simple" "Use defaults (1 vCPU, 1GB RAM, 12GB disk, name: phev2mqtt)" \
        "Advanced" "Customize VM settings" \
        3>&1 1>&2 2>&3)
    
    if [[ $? -ne 0 || -z "$MODE" ]]; then
        die "Installation cancelled by user"
    fi
    
    log_info "Selected mode: ${MODE}"
}

advanced_settings_ram() {
    local ram_choice
    ram_choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "Memory" \
        --default-item "1024" \
        --menu "Amount of RAM (default: 1GB):" \
        14 50 4 \
        "512"  "512MB — not recommended" \
        "1024" "1GB (default)" \
        "2048" "2GB" \
        "4096" "4GB" \
        3>&1 1>&2 2>&3)
    [[ $? -ne 0 ]] && die "Installation cancelled by user"

    if [[ "$ram_choice" == "512" ]]; then
        if whiptail --backtitle "Proxmox VE Helper Scripts" \
            --title "Memory Warning" \
            --yesno "⚠ 512MB is not recommended. See README for details.\n\nDo you want to re-select memory allocation?" \
            --yes-button "Re-select" \
            --no-button "Continue anyway" \
            10 60; then
            # User chose Re-select
            advanced_settings_ram
            return
        fi
    fi

    VM_MEMORY="$ram_choice"
}

advanced_settings_disk() {
    while true; do
        local input
        input=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
            --title "Disk Size" \
            --inputbox "Enter VM disk size in GB (minimum 12, default 12):\nExamples: 12, 20, 32, 50" \
            10 60 "${VM_DISK_SIZE%G}" \
            3>&1 1>&2 2>&3)
        [[ $? -ne 0 ]] && die "Installation cancelled by user"

        # Strip any trailing G the user may have typed
        input="${input//G/}"
        input="${input// /}"

        # Validate: must be a positive integer >= 12
        if ! [[ "$input" =~ ^[0-9]+$ ]] || [[ "$input" -lt 12 ]]; then
            whiptail --backtitle "Proxmox VE Helper Scripts" \
                --title "Invalid Disk Size" \
                --msgbox "Disk size must be a number >= 12 GB." \
                8 50
            continue
        fi

        VM_DISK_SIZE="${input}G"
        break
    done
}

advanced_settings() {
    # VM Name
    VM_NAME=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "VM Name" \
        --inputbox "Enter a name for the VM:" \
        10 60 "${VM_NAME}" \
        3>&1 1>&2 2>&3)
    [[ $? -ne 0 ]] && die "Installation cancelled by user"

    # CPU cores
    VM_CORES=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "CPU Cores" \
        --menu "Number of vCPUs (default: 1):" \
        12 50 4 \
        "1" "1 vCPU (default)" \
        "2" "2 vCPUs" \
        "3" "3 vCPUs" \
        "4" "4 vCPUs" \
        3>&1 1>&2 2>&3)
    [[ $? -ne 0 ]] && die "Installation cancelled by user"

    # RAM
    advanced_settings_ram

    # Disk size
    advanced_settings_disk
}

select_vmid() {
    # Get suggested VMID using pvesh
    local suggested_vmid
    suggested_vmid=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
    
    while true; do
        local input
        input=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
            --title "VM ID Selection" \
            --inputbox "Enter VM ID for phev2mqtt VM.\n\nSuggested (next available): ${suggested_vmid}" \
            12 60 "${suggested_vmid}" 3>&1 1>&2 2>&3)
        
        # User cancelled
        if [[ $? -ne 0 ]]; then
            die "Installation cancelled by user"
        fi
        
        # Validate input is numeric
        if ! [[ "$input" =~ ^[0-9]+$ ]]; then
            whiptail --backtitle "Proxmox VE Helper Scripts" \
                --title "Invalid Input" --msgbox "VM ID must be a number." 8 50
            continue
        fi
        
        # Check if VMID is already in use by checking config files
        if [[ -f "/etc/pve/qemu-server/${input}.conf" ]] || [[ -f "/etc/pve/lxc/${input}.conf" ]]; then
            whiptail --backtitle "Proxmox VE Helper Scripts" \
                --title "VMID In Use" --msgbox "VMID ${input} is already in use. Please choose a different ID." 8 60
            continue
        fi
        
        VMID="$input"
        log_info "Selected VMID: ${VMID}"
        break
    done
}

select_storage() {
    # Get available storage pools
    local storage_list
    storage_list=$(pvesm status -content images | awk 'NR>1 {printf "%s %s %s\n", $1, $2, "ON"}')
    
    if [[ -z "$storage_list" ]]; then
        die "No storage pools available for VM images"
    fi
    
    local storage_menu=()
    while IFS= read -r line; do
        local name type status
        name=$(echo "$line" | awk '{print $1}')
        type=$(echo "$line" | awk '{print $2}')
        storage_menu+=("$name" "$type")
    done <<<"$storage_list"
    
    STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "Storage Pool Selection" \
        --menu "Select storage pool for VM disk:" \
        18 70 10 \
        "${storage_menu[@]}" \
        3>&1 1>&2 2>&3)
    
    if [[ $? -ne 0 || -z "$STORAGE" ]]; then
        die "Installation cancelled by user"
    fi
    
    log_info "Selected storage: ${STORAGE}"
}

select_usb_adapter() {
    # Get ALL USB devices
    local usb_devices
    usb_devices=$(lsusb)
    
    if [[ -z "$usb_devices" ]]; then
        die "No USB devices found. Please connect a USB WiFi adapter and try again."
    fi
    
    # Parse USB devices into menu format
    local menu_items=()
    local device_map=()
    local index=1
    
    while IFS= read -r line; do
        # Extract Bus, Device, ID, and Description
        # Format: Bus 001 Device 003: ID 2357:0138 TP-Link xyz
        local bus device id desc
        bus=$(echo "$line" | awk '{print $2}')
        device=$(echo "$line" | awk '{print $4}' | tr -d ':')
        id=$(echo "$line" | awk '{print $6}')
        desc=$(echo "$line" | cut -d' ' -f7-)
        
        menu_items+=("$index" "${id} - ${desc}")
        device_map+=("${bus}|${device}|${id}")
        ((index++))
    done <<<"$usb_devices"
    
    if [[ ${#menu_items[@]} -eq 0 ]]; then
        die "No USB devices found. Please connect a USB WiFi adapter and try again."
    fi
    
    local selection
    selection=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "USB WiFi Adapter Selection" \
        --menu "Select the USB WiFi adapter to pass through (showing all USB devices):\n\nNote: The adapter will be dedicated to the VM." \
        22 78 12 \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3)
    
    if [[ $? -ne 0 || -z "$selection" ]]; then
        die "Installation cancelled by user"
    fi
    
    # Get selected device info
    local device_info="${device_map[$((selection - 1))]}"
    local bus device id
    bus=$(echo "$device_info" | cut -d'|' -f1)
    device=$(echo "$device_info" | cut -d'|' -f2)
    id=$(echo "$device_info" | cut -d'|' -f3)
    
    USB_DEVICE="${bus}-${device}"
    USB_ID="$id"
    
    log_info "Selected USB device: Bus ${bus} Device ${device} ID ${id}"
    
    # Lookup driver in adapters.txt
    lookup_usb_driver
}

lookup_usb_driver() {
    # Download adapters.txt
    local adapters_file="${TEMP_DIR}/adapters.txt"
    if ! curl -fsSL "$ADAPTERS_URL" -o "$adapters_file"; then
        log_warn "Failed to download adapter lookup table. Proceeding without driver info."
        USB_DRIVER="unknown"
        USB_NOTES="Unknown adapter - driver must be installed manually"
        return
    fi
    
    # Lookup USB_ID (case-insensitive)
    local lookup_line
    lookup_line=$(grep -iE "^${USB_ID}\s+" "$adapters_file" 2>/dev/null || true)
    
    if [[ -n "$lookup_line" ]]; then
        # Parse: USB_ID CHIPSET DRIVER NOTES
        USB_DRIVER=$(echo "$lookup_line" | awk '{print $3}')
        USB_NOTES=$(echo "$lookup_line" | cut -d' ' -f4-)
        
        whiptail --backtitle "Proxmox VE Helper Scripts" \
            --title "Adapter Recognized" \
            --msgbox "✓ Supported adapter detected!\n\nUSB ID: ${USB_ID}\nDriver: ${USB_DRIVER}\nInfo: ${USB_NOTES}\n\nThe driver will be installed automatically during VM setup." \
            14 70
    else
        USB_DRIVER="unknown"
        USB_NOTES="Unknown adapter"
        
        if ! whiptail --backtitle "Proxmox VE Helper Scripts" \
            --title "Unknown Adapter" \
            --yesno "⚠ Adapter not in supported list.\n\nUSB ID: ${USB_ID}\n\nYou may need to install the driver manually after installation.\n\nProceed anyway?" \
            12 70; then
            die "Installation cancelled by user"
        fi
    fi
    
    log_info "Adapter info - Driver: ${USB_DRIVER}, Notes: ${USB_NOTES}"
}

show_confirmation() {
    local summary="VM Configuration Summary:\n\n"
    summary+="VM Name: ${VM_NAME}\n"
    summary+="VM ID: ${VMID}\n"
    summary+="Storage: ${STORAGE}\n"
    summary+="CPU: ${VM_CORES} vCore(s)\n"
    summary+="Memory: ${VM_MEMORY} MB\n"
    summary+="Disk: ${VM_DISK_SIZE}\n"
    summary+="OS: Debian 12 (Bookworm)\n\n"
    summary+="USB Adapter:\n"
    summary+="  ID: ${USB_ID}\n"
    summary+="  Driver: ${USB_DRIVER}\n"
    summary+="  Info: ${USB_NOTES}\n\n"
    summary+="Proceed with installation?"
    
    if ! whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "Confirmation" --yesno "$summary" 22 70; then
        die "Installation cancelled by user"
    fi
}

# ============================================================================
# VM Creation Functions
# ============================================================================

download_debian_image() {
    log_info "Downloading Debian 12 cloud image..." >&2
    
    local image_file="${TEMP_DIR}/debian-12-generic-amd64.qcow2"
    
    if ! wget -q --show-progress -O "$image_file" "$DEBIAN_IMAGE_URL"; then
        die "Failed to download Debian cloud image"
    fi
    
    # Verify checksum if available
    log_info "Verifying image checksum..." >&2
    local checksum_file="${TEMP_DIR}/SHA512SUMS"
    if wget -q -O "$checksum_file" "$DEBIAN_IMAGE_CHECKSUM_URL" 2>/dev/null; then
        if ! (cd "$TEMP_DIR" && sha512sum -c --ignore-missing "$checksum_file" &>/dev/null); then
            log_warn "Checksum verification failed - proceeding anyway" >&2
        else
            log_info "Checksum verified successfully" >&2
        fi
    else
        log_warn "Could not download checksum file - skipping verification" >&2
    fi
    
    echo "$image_file"
}

create_vm() {
    log_info "Creating VM ${VMID}..."
    
    # Download Debian image
    local image_file
    image_file=$(download_debian_image)
    
    # Mark that we've created a VM (for cleanup on error)
    CREATED_VMID="$VMID"
    
    # Create VM
    qm create "$VMID" \
        --name "${VM_NAME}" \
        --cores "$VM_CORES" \
        --memory "$VM_MEMORY" \
        --net0 "virtio,bridge=vmbr0" \
        --ostype "$VM_OS_TYPE" \
        --scsihw "virtio-scsi-pci" \
        || die "Failed to create VM"
    
    log_info "Importing disk image..."
    
    # Import disk and capture output to extract actual disk path
    local import_output
    import_output=$(qm importdisk "$VMID" "$image_file" "$STORAGE" 2>&1) \
      || die "Failed to import disk: ${import_output}"
    local imported_disk
    imported_disk=$(echo "$import_output" | grep -oP "[a-zA-Z0-9_\-]+:vm-${VMID}-disk-[0-9]+" | tail -n1)
    if [[ -z "$imported_disk" ]]; then
      die "Could not determine imported disk path. Import output: ${import_output}"
    fi
    log_info "Imported disk: ${imported_disk}"
    
    log_info "Configuring VM hardware..."
    
    # Attach disk
    qm set "$VMID" \
        --scsi0 "${imported_disk}" \
        --boot "order=scsi0" \
        --serial0 socket \
        --vga serial0 \
        || die "Failed to configure VM disk"
    
    # Resize disk
    qm resize "$VMID" scsi0 "$VM_DISK_SIZE" \
        || die "Failed to resize disk"
    
    log_info "Configuring cloud-init..."
    
    # Add cloud-init drive
    qm set "$VMID" \
        --ide2 "${STORAGE}:cloudinit" \
        --ciuser "root" \
        --ipconfig0 "ip=dhcp" \
        || die "Failed to configure cloud-init"
    
    # Download and configure vm-setup.sh via cloud-init custom script
    local vm_setup_script="${TEMP_DIR}/vm-setup.sh"
    log_info "Downloading VM setup script..."
    
    if ! curl -fsSL "$VM_SETUP_URL" -o "$vm_setup_script"; then
        die "Failed to download VM setup script"
    fi
    
    # Create snippets directory if it doesn't exist
    local snippets_dir="/var/lib/vz/snippets"
    mkdir -p "$snippets_dir"
    
    # Copy vm-setup.sh to snippets
    local snippet_file="${snippets_dir}/phev2mqtt-setup-${VMID}.sh"
    cp "$vm_setup_script" "$snippet_file"
    chmod +x "$snippet_file"
    
    # Configure cloud-init to run setup script
    qm set "$VMID" \
        --cicustom "user=local:snippets/phev2mqtt-setup-${VMID}.sh" \
        || log_warn "Failed to set cloud-init custom script - VM may need manual setup"
    
    log_info "Configuring USB passthrough..."
    
    # Configure USB passthrough
    configure_usb_passthrough
    
    log_info "VM ${VMID} created successfully"
}

configure_usb_passthrough() {
    # Parse USB_ID to vendor and product
    local vendor product
    vendor=$(echo "$USB_ID" | cut -d: -f1)
    product=$(echo "$USB_ID" | cut -d: -f2)
    
    # Add USB device passthrough
    qm set "$VMID" \
        --usb0 "host=${vendor}:${product},usb3=1" \
        || die "Failed to configure USB passthrough"
    
    log_info "USB passthrough configured for ${USB_ID}"
}

start_vm() {
    log_info "Starting VM ${VMID}..."
    
    if ! qm start "$VMID"; then
        die "Failed to start VM"
    fi
    
    log_info "VM started successfully. Waiting for network..."
    
    # Wait for VM to get IP address (timeout after 60 seconds)
    local timeout=60
    local elapsed=0
    local vm_ip=""
    
    while [[ $elapsed -lt $timeout ]]; do
        vm_ip=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | \
            grep -oP '(?<="ip-address":")[0-9.]+' | \
            grep -v '127.0.0.1' | head -n1 || true)
        
        if [[ -n "$vm_ip" ]]; then
            break
        fi
        
        sleep 2
        ((elapsed += 2))
    done
    
    if [[ -z "$vm_ip" ]]; then
        log_warn "Could not detect VM IP address automatically"
        vm_ip="<check Proxmox console>"
    fi
    
    # Installation complete
    whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "Installation Complete!" \
        --msgbox "✓ VM ${VMID} created and started successfully!\n\nVM IP: ${vm_ip}\nWeb UI: http://${vm_ip}:8080\n\nThe VM is now performing first-boot setup (installing drivers, building phev2mqtt). This may take 5-10 minutes.\n\nOnce ready, open the web UI in your browser to:\n1. Set your web UI password\n2. Configure WiFi connection to your car\n3. Configure MQTT broker connection\n\nDocumentation: ${REPO_RAW_BASE}/README.md" \
        20 78
    
    log_info "================================================================"
    log_info "Installation complete!"
    log_info "VM ID: ${VMID}"
    log_info "VM IP: ${vm_ip}"
    log_info "Web UI: http://${vm_ip}:8080"
    log_info "================================================================"
    
    # Clear CREATED_VMID so cleanup doesn't destroy the successfully created VM
    CREATED_VMID=""
}

# ============================================================================
# Main
# ============================================================================

main() {
    log_info "phev2mqtt Proxmox Installer v${SCRIPT_VERSION}"
    log_info "================================================================"
    
    # Pre-flight checks
    check_root
    check_proxmox
    check_dependencies
    check_snippets_storage
    
    # Create temp directory
    TEMP_DIR=$(mktemp -d)
    log_info "Temp directory: ${TEMP_DIR}"
    
    # Interactive dialogs
    show_welcome
    select_mode
    
    if [[ "$MODE" == "Advanced" ]]; then
        advanced_settings
    fi
    
    select_vmid
    select_storage
    select_usb_adapter
    show_confirmation
    
    # VM creation
    create_vm
    start_vm
    
    log_info "Done!"
}

main "$@"
