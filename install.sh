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

DEBIAN_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
DEBIAN_IMAGE_CHECKSUM_URL="https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS"

# VM defaults
VMID=""
VM_NAME="phev2mqtt"
HN="phev2mqtt"
CPU_TYPE=""
VM_MACHINE_TYPE=""
CORE_COUNT=1
RAM_SIZE=1024
DISK_SIZE="12G"
DISK_CACHE=""
BRG="vmbr0"
VLAN=""
MTU=""
START_VM="yes"
GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
MAC="$GEN_MAC"

# Storage type detection results
DISK_EXT=""
DISK_REF=""
DISK_IMPORT=""
THIN="discard=on,ssd=1,"

STORAGE=""
USB_DEVICE=""
USB_ID=""
USB_DRIVER=""
USB_NOTES=""
SSH_PASSWORD=""
TEMP_DIR=""
CREATED_VMID=""
MODE="Simple"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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
    local deps=(whiptail curl lsusb wget numfmt virt-customize)
    local missing=()
    
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            # Special handling for virt-customize — try to install libguestfs-tools
            if [[ "$cmd" == "virt-customize" ]]; then
                log_info "Installing libguestfs-tools..."
                apt-get -qq update
                apt-get -qq install -y libguestfs-tools || missing+=("libguestfs-tools")
            else
                missing+=("$cmd")
            fi
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}"
    fi
}

# ============================================================================
# Whiptail Dialog Functions
# ============================================================================

show_welcome() {
    whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "phev2mqtt Proxmox Installer v${SCRIPT_VERSION}" \
        --msgbox "This installer will create a Debian 12 VM configured as a phev2mqtt gateway for Mitsubishi Outlander PHEV vehicles.\n\nWhat will be installed:\n- Debian 12 VM with OVMF/UEFI bios\n- USB WiFi adapter passthrough\n- phev2mqtt binary (built from source)\n- Web UI for configuration and management\n\nAfter installation, configure WiFi and MQTT via the web interface.\n\nDocumentation: ${REPO_RAW_BASE}/README.md" \
        20 78
}

default_settings() {
    MODE="Simple"
    log_info "Using default settings:"
    log_info "  VM Name:   ${HN}"
    log_info "  CPU Model: KVM64"
    log_info "  Cores:     ${CORE_COUNT}"
    log_info "  RAM:       ${RAM_SIZE} MiB"
    log_info "  Disk:      ${DISK_SIZE}"
    log_info "  Bridge:    ${BRG}"
    log_info "  MAC:       ${MAC}"
}

select_mode() {
    if ! whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "SETTINGS" \
        --yesno "Use Default Settings?" \
        --no-button "Advanced" \
        10 58; then
        MODE="Advanced"
    else
        MODE="Simple"
    fi
    log_info "Selected mode: ${MODE}"
}

advanced_settings() {
    MODE="Advanced"

    # VIRTUAL MACHINE ID — community-scripts pattern
    while true; do
        if VMID=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
            --title "VIRTUAL MACHINE ID" \
            --cancel-button "Exit-Script" \
            --inputbox "Set Virtual Machine ID" \
            8 58 "$(pvesh get /cluster/nextid 2>/dev/null || echo 100)" \
            3>&1 1>&2 2>&3); then
            [[ -z "$VMID" ]] && VMID=$(pvesh get /cluster/nextid 2>/dev/null || echo 100)
            if pct status "$VMID" &>/dev/null || qm status "$VMID" &>/dev/null; then
                whiptail --backtitle "Proxmox VE Helper Scripts" \
                    --title "ID In Use" \
                    --msgbox "ID $VMID is already in use." 8 50
                continue
            fi
            log_info "VM ID: ${VMID}"
            break
        else
            die "Installation cancelled by user"
        fi
    done

    # MACHINE TYPE
    local mach
    if mach=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "MACHINE TYPE" \
        --cancel-button "Exit-Script" \
        --radiolist "Choose Type" \
        10 58 2 \
        "i440fx" "Machine i440fx" ON \
        "q35"    "Machine q35"    OFF \
        3>&1 1>&2 2>&3); then
        if [[ "$mach" == "q35" ]]; then
            VM_MACHINE_TYPE=" -machine q35"
        else
            VM_MACHINE_TYPE=""
        fi
        log_info "Machine type: ${mach}"
    else
        die "Installation cancelled by user"
    fi

    # DISK SIZE
    while true; do
        local disk_input
        if disk_input=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
            --title "DISK SIZE" \
            --cancel-button "Exit-Script" \
            --inputbox "Set Disk Size in GiB (e.g., 12, 20)" \
            8 58 "${DISK_SIZE%G}" \
            3>&1 1>&2 2>&3); then
            disk_input="${disk_input// /}"
            disk_input="${disk_input//G/}"
            if [[ "$disk_input" =~ ^[0-9]+$ ]] && [[ "$disk_input" -ge 12 ]]; then
                DISK_SIZE="${disk_input}G"
                log_info "Disk size: ${DISK_SIZE}"
                break
            fi
            whiptail --backtitle "Proxmox VE Helper Scripts" \
                --title "Invalid Input" \
                --msgbox "Disk size must be a number >= 12 GiB." 8 50
        else
            die "Installation cancelled by user"
        fi
    done

    # DISK CACHE
    local cache_choice
    if cache_choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "DISK CACHE" \
        --cancel-button "Exit-Script" \
        --radiolist "Choose" \
        10 58 2 \
        "0" "None (Default)" ON \
        "1" "Write Through"  OFF \
        3>&1 1>&2 2>&3); then
        if [[ "$cache_choice" == "1" ]]; then
            DISK_CACHE="cache=writethrough,"
            log_info "Disk cache: Write Through"
        else
            DISK_CACHE=""
            log_info "Disk cache: None"
        fi
    else
        die "Installation cancelled by user"
    fi

    # HOSTNAME
    local hn_input
    if hn_input=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "HOSTNAME" \
        --cancel-button "Exit-Script" \
        --inputbox "Set Hostname" \
        8 58 "${HN}" \
        3>&1 1>&2 2>&3); then
        HN="${hn_input:-phev2mqtt}"
        HN="${HN,,}"
        HN="${HN// /}"
        VM_NAME="$HN"
        log_info "Hostname: ${HN}"
    else
        die "Installation cancelled by user"
    fi

    # CPU MODEL
    local cpu_choice
    if cpu_choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "CPU MODEL" \
        --cancel-button "Exit-Script" \
        --radiolist "Choose" \
        10 58 2 \
        "0" "KVM64 (Default)" ON \
        "1" "Host"            OFF \
        3>&1 1>&2 2>&3); then
        if [[ "$cpu_choice" == "1" ]]; then
            CPU_TYPE=" -cpu host"
            log_info "CPU model: Host"
        else
            CPU_TYPE=""
            log_info "CPU model: KVM64"
        fi
    else
        die "Installation cancelled by user"
    fi

    # CORE COUNT
    while true; do
        local cores_input
        if cores_input=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
            --title "CORE COUNT" \
            --cancel-button "Exit-Script" \
            --inputbox "Allocate CPU Cores" \
            8 58 "${CORE_COUNT}" \
            3>&1 1>&2 2>&3); then
            if [[ "$cores_input" =~ ^[0-9]+$ ]] && [[ "$cores_input" -ge 1 ]]; then
                CORE_COUNT="$cores_input"
                log_info "CPU cores: ${CORE_COUNT}"
                break
            fi
            whiptail --backtitle "Proxmox VE Helper Scripts" \
                --title "Invalid Input" \
                --msgbox "CPU cores must be a number >= 1." 8 50
        else
            die "Installation cancelled by user"
        fi
    done

    # RAM
    while true; do
        local ram_input
        if ram_input=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
            --title "RAM" \
            --cancel-button "Exit-Script" \
            --inputbox "Allocate RAM in MiB" \
            8 58 "${RAM_SIZE}" \
            3>&1 1>&2 2>&3); then
            if ! [[ "$ram_input" =~ ^[0-9]+$ ]] || [[ "$ram_input" -lt 512 ]]; then
                whiptail --backtitle "Proxmox VE Helper Scripts" \
                    --title "Invalid Input" \
                    --msgbox "RAM must be a number >= 512 MiB." 8 50
                continue
            fi
            if [[ "$ram_input" -lt 1024 ]]; then
                if whiptail --backtitle "Proxmox VE Helper Scripts" \
                    --title "RAM" \
                    --yesno "⚠ ${ram_input}MiB is not recommended.\n\nGo back and re-select?" \
                    --yes-button "Re-select" \
                    --no-button "Continue anyway" \
                    10 60; then
                    continue
                fi
            fi
            RAM_SIZE="$ram_input"
            log_info "RAM: ${RAM_SIZE} MiB"
            break
        else
            die "Installation cancelled by user"
        fi
    done

    # BRIDGE
    local brg_input
    if brg_input=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "BRIDGE" \
        --cancel-button "Exit-Script" \
        --inputbox "Set a Bridge" \
        8 58 "${BRG}" \
        3>&1 1>&2 2>&3); then
        BRG="${brg_input:-vmbr0}"
        log_info "Bridge: ${BRG}"
    else
        die "Installation cancelled by user"
    fi

    # MAC ADDRESS
    local mac_input
    if mac_input=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "MAC ADDRESS" \
        --cancel-button "Exit-Script" \
        --inputbox "Set a MAC Address" \
        8 58 "${GEN_MAC}" \
        3>&1 1>&2 2>&3); then
        MAC="${mac_input:-$GEN_MAC}"
        log_info "MAC: ${MAC}"
    else
        die "Installation cancelled by user"
    fi

    # VLAN
    local vlan_input
    if vlan_input=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "VLAN" \
        --cancel-button "Exit-Script" \
        --inputbox "Set a Vlan (leave blank for default)" \
        8 58 "" \
        3>&1 1>&2 2>&3); then
        if [[ -n "$vlan_input" ]]; then
            VLAN=",tag=${vlan_input}"
            log_info "VLAN: ${vlan_input}"
        else
            VLAN=""
            log_info "VLAN: Default"
        fi
    else
        die "Installation cancelled by user"
    fi

    # MTU SIZE
    local mtu_input
    if mtu_input=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "MTU SIZE" \
        --cancel-button "Exit-Script" \
        --inputbox "Set Interface MTU Size (leave blank for default)" \
        8 58 "" \
        3>&1 1>&2 2>&3); then
        if [[ -n "$mtu_input" ]]; then
            MTU=",mtu=${mtu_input}"
            log_info "MTU: ${mtu_input}"
        else
            MTU=""
            log_info "MTU: Default"
        fi
    else
        die "Installation cancelled by user"
    fi

    # START VM
    if whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "START VIRTUAL MACHINE" \
        --yesno "Start VM when completed?" \
        10 58; then
        START_VM="yes"
        log_info "Start VM: yes"
    else
        START_VM="no"
        log_info "Start VM: no"
    fi

    # ADVANCED SETTINGS COMPLETE — Do-Over loop
    if ! whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "ADVANCED SETTINGS COMPLETE" \
        --yesno "Ready to create a phev2mqtt VM?" \
        --no-button "Do-Over" \
        10 58; then
        advanced_settings
        return
    fi
}

select_vmid() {
    # Only called in Simple mode — Advanced mode sets VMID internally
    local suggested_vmid
    suggested_vmid=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")

    while true; do
        local input
        input=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
            --title "VIRTUAL MACHINE ID" \
            --cancel-button "Exit-Script" \
            --inputbox "Set Virtual Machine ID" \
            8 58 "${suggested_vmid}" \
            3>&1 1>&2 2>&3)
        [[ $? -ne 0 ]] && die "Installation cancelled by user"

        if ! [[ "$input" =~ ^[0-9]+$ ]]; then
            whiptail --backtitle "Proxmox VE Helper Scripts" \
                --title "Invalid Input" \
                --msgbox "VM ID must be a number." 8 50
            continue
        fi
        if pct status "$input" &>/dev/null || qm status "$input" &>/dev/null; then
            whiptail --backtitle "Proxmox VE Helper Scripts" \
                --title "ID In Use" \
                --msgbox "ID $input is already in use." 8 60
            continue
        fi
        VMID="$input"
        log_info "Selected VMID: ${VMID}"
        break
    done
}

select_storage() {
    local storage_menu=()
    local msg_max_length=0

    while read -r line; do
        local tag type free item offset
        tag=$(echo "$line" | awk '{print $1}')
        type=$(echo "$line" | awk '{printf "%-10s", $2}')
        free=$(echo "$line" | numfmt --field 4-6 --from-unit=K \
            --to=iec --format %.2f 2>/dev/null | \
            awk '{printf("%9sB", $6)}' 2>/dev/null || echo "       ?B")
        item="  Type: ${type} Free: ${free} "
        offset=2
        if [[ $((${#item} + offset)) -gt ${msg_max_length} ]]; then
            msg_max_length=$((${#item} + offset))
        fi
        storage_menu+=("$tag" "$item" "OFF")
    done < <(pvesm status -content images | awk 'NR>1')

    if [[ ${#storage_menu[@]} -eq 0 ]]; then
        die "No storage pools available for VM images"
    fi

    # If only one storage, select it automatically
    if [[ $((${#storage_menu[@]} / 3)) -eq 1 ]]; then
        STORAGE="${storage_menu[0]}"
        log_info "Selected storage: ${STORAGE} (only option)"
        return
    fi

    # Pre-select first entry
    storage_menu[2]="ON"

    while [[ -z "${STORAGE}" ]]; do
        STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
            --title "Storage Pools" \
            --radiolist \
            "Which storage pool would you like to use for ${HN}?\nTo make a selection, use the Spacebar.\n" \
            16 $((msg_max_length + 23)) 6 \
            "${storage_menu[@]}" \
            3>&1 1>&2 2>&3)
        [[ $? -ne 0 ]] && die "Installation cancelled by user"
    done

    log_info "Selected storage: ${STORAGE}"
}

select_ssh_password() {
    while true; do
        local pw1
        if pw1=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
            --title "SSH / CONSOLE PASSWORD" \
            --passwordbox "Set a root password for SSH and console access (min 8 characters)" \
            10 58 \
            3>&1 1>&2 2>&3); then
            if [[ -z "$pw1" ]]; then
                die "Installation cancelled by user"
            fi
        else
            die "Installation cancelled by user"
        fi

        if [[ ${#pw1} -lt 8 ]]; then
            whiptail --backtitle "Proxmox VE Helper Scripts" \
                --title "Invalid Password" \
                --msgbox "Password must be at least 8 characters." 8 50
            continue
        fi

        local pw2
        if pw2=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
            --title "CONFIRM PASSWORD" \
            --passwordbox "Confirm password" \
            10 58 \
            3>&1 1>&2 2>&3); then
            if [[ -z "$pw2" ]]; then
                die "Installation cancelled by user"
            fi
        else
            die "Installation cancelled by user"
        fi

        if [[ "$pw1" != "$pw2" ]]; then
            whiptail --backtitle "Proxmox VE Helper Scripts" \
                --title "Password Mismatch" \
                --msgbox "Passwords do not match. Please try again." 8 50
            continue
        fi

        SSH_PASSWORD="$pw1"
        log_info "SSH password set"
        break
    done
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

customize_image() {
    local image_file="$1"
    local ssh_password="$2"
    
    log_info "Customizing disk image with virt-customize..."
    
    virt-customize -a "$image_file" \
        --install "git,build-essential,curl,wget,usbutils,dkms,bc,python3,python3-pip,python3-venv,qemu-guest-agent,openssh-server,linux-headers-generic" \
        --run-command "go_version=\$(curl -fsSL https://go.dev/VERSION?m=text | head -1) && wget -q \"https://go.dev/dl/\${go_version}.linux-amd64.tar.gz\" -O /tmp/go.tar.gz && rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tar.gz && rm /tmp/go.tar.gz && echo 'export PATH=\$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh" \
        --run-command "export PATH=\$PATH:/usr/local/go/bin && export GOPATH=/root/go && export GOMODCACHE=/root/go/pkg/mod && export GOCACHE=/root/.cache/go-build && mkdir -p /root/go /root/go/pkg/mod /root/.cache/go-build && git clone https://github.com/buxtronix/phev2mqtt.git /tmp/phev2mqtt-build && cd /tmp/phev2mqtt-build && /usr/local/go/bin/go build -o /usr/local/bin/phev2mqtt && chmod +x /usr/local/bin/phev2mqtt && rm -rf /tmp/phev2mqtt-build" \
        --run-command "mkdir -p /opt/phev2mqtt-webui /etc/phev2mqtt-webui /var/log/phev2mqtt-webui && wget -q https://github.com/corautem/phev2mqtt-vm/archive/refs/heads/main.tar.gz -O /tmp/phev2mqtt-vm.tar.gz && tar -xzf /tmp/phev2mqtt-vm.tar.gz -C /tmp/ && cp -r /tmp/phev2mqtt-vm-main/webui/* /opt/phev2mqtt-webui/ && cp /tmp/phev2mqtt-vm-main/systemd/phev2mqtt-webui.service /etc/systemd/system/phev2mqtt-webui.service && cp /tmp/phev2mqtt-vm-main/systemd/phev2mqtt.service /etc/systemd/system/phev2mqtt.service && mkdir -p /etc/systemd/journald.conf.d && cp /tmp/phev2mqtt-vm-main/config/journald.conf /etc/systemd/journald.conf.d/phev2mqtt.conf && cp /tmp/phev2mqtt-vm-main/config/logrotate.phev2mqtt-webui /etc/logrotate.d/phev2mqtt-webui && rm -rf /tmp/phev2mqtt-vm.tar.gz /tmp/phev2mqtt-vm-main" \
        --run-command "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && export HOME=/root && export TMPDIR=/var/tmp && export XDG_CACHE_HOME=/var/tmp/pip-cache && mkdir -p /var/tmp/pip-cache && python3 -m venv /opt/phev2mqtt-webui/venv && cd /opt/phev2mqtt-webui && ./venv/bin/python3 -m pip install --no-cache-dir -r /opt/phev2mqtt-webui/requirements.txt" \
        --run-command "mkdir -p /etc/systemd/network && printf '[Match]\nName=e*\n\n[Network]\nDHCP=yes\n' > /etc/systemd/network/20-dhcp.conf && systemctl enable systemd-networkd && systemctl enable systemd-resolved && ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf && systemctl enable qemu-guest-agent && systemctl enable phev2mqtt-webui && systemctl enable ssh && sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && touch /etc/phev2mqtt-webui/phev2mqtt.env && chmod 600 /etc/phev2mqtt-webui/phev2mqtt.env && chown -R root:root /opt/phev2mqtt-webui && chmod -R 755 /opt/phev2mqtt-webui && chmod 700 /etc/phev2mqtt-webui" \
        --run-command "ssh-keygen -A" \
        --root-password "password:${ssh_password}" \
        --hostname "${HN}" \
        --run-command "echo -n > /etc/machine-id" \
        || die "Image customization failed"
    
    log_info "Image customization complete"
}

show_confirmation() {
    # Only called in Simple mode
    local machine_display="i440fx"
    [[ -n "$VM_MACHINE_TYPE" ]] && machine_display="q35"

    local summary="VM Configuration Summary:\n\n"
    summary+="Hostname: ${HN}\n"
    summary+="VM ID: ${VMID}\n"
    summary+="Storage: ${STORAGE}\n"
    summary+="CPU Model: KVM64\n"
    summary+="CPU Cores: ${CORE_COUNT}\n"
    summary+="Memory: ${RAM_SIZE} MiB\n"
    summary+="Disk: ${DISK_SIZE}\n"
    summary+="Machine: i440fx\n"
    summary+="Bridge: ${BRG}\n"
    summary+="MAC: ${MAC}\n"
    summary+="SSH/Console Password: ********\n"
    summary+="OS: Debian 12 (Bookworm)\n\n"
    summary+="USB Adapter:\n"
    summary+="  ID: ${USB_ID}\n"
    summary+="  Driver: ${USB_DRIVER}\n\n"
    summary+="Proceed with installation?"

    if ! whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "Debian 12 VM" \
        --yesno "$summary" 26 70; then
        die "Installation cancelled by user"
    fi
}

create_vm() {
    log_info "Creating VM ${VMID}..."

    local image_file
    image_file=$(download_debian_image)
    CREATED_VMID="$VMID"

    customize_image "$image_file" "$SSH_PASSWORD"

    # Detect storage type and set disk format accordingly
    local storage_type
    storage_type=$(pvesm status -storage "$STORAGE" | awk 'NR>1 {print $2}')
    case "$storage_type" in
        nfs|dir)
            DISK_EXT=".qcow2"
            DISK_REF="${VMID}/"
            DISK_IMPORT="-format qcow2"
            THIN=""
            ;;
        btrfs)
            DISK_EXT=".raw"
            DISK_REF="${VMID}/"
            DISK_IMPORT="-format raw"
            THIN=""
            ;;
        *)
            DISK_EXT=""
            DISK_REF=""
            DISK_IMPORT="-format raw"
            ;;
    esac

    local DISK0="vm-${VMID}-disk-0${DISK_EXT}"
    local DISK1="vm-${VMID}-disk-1${DISK_EXT}"
    local DISK0_REF="${STORAGE}:${DISK_REF}${DISK0}"
    local DISK1_REF="${STORAGE}:${DISK_REF}${DISK1}"

    log_info "Importing disk image..."
    qm create "$VMID" \
        -agent 1 \
        ${VM_MACHINE_TYPE} \
        -tablet 0 \
        -localtime 1 \
        -bios ovmf \
        ${CPU_TYPE} \
        -cores "$CORE_COUNT" \
        -memory "$RAM_SIZE" \
        -name "$HN" \
        -net0 "virtio,bridge=${BRG},macaddr=${MAC},firewall=0${VLAN}${MTU}" \
        -onboot 1 \
        -ostype l26 \
        -scsihw virtio-scsi-pci \
        || die "Failed to create VM"

    pvesm alloc "$STORAGE" "$VMID" "$DISK0" 4M 1>/dev/null \
        || die "Failed to allocate EFI disk"

    qm importdisk "$VMID" "$image_file" "$STORAGE" ${DISK_IMPORT} \
        1>/dev/null || die "Failed to import disk"

    qm set "$VMID" \
        -efidisk0 "${DISK0_REF},efitype=4m" \
        -scsi0 "${DISK1_REF},${DISK_CACHE}${THIN}size=${DISK_SIZE}" \
        -boot order=scsi0 \
        -serial0 socket \
        -ciuser debian \
        -cipassword "${SSH_PASSWORD}" \
        -ipconfig0 "ip=dhcp" \
        || die "Failed to configure VM"

    log_info "Resizing disk to ${DISK_SIZE}..."
    qm resize "$VMID" scsi0 "${DISK_SIZE}" 1>/dev/null \
        || die "Failed to resize disk"

    log_info "Configuring USB passthrough..."
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
    if [[ "$START_VM" != "yes" ]]; then
        whiptail --backtitle "Proxmox VE Helper Scripts" \
            --title "Installation Complete!" \
            --msgbox "✓ VM ${VMID} created successfully.\n\nStart VM manually when ready:\n  qm start ${VMID}\n\nThen find IP via Proxmox UI → VM ${VMID} → Summary → IPs\nWeb UI: http://<VM_IP>:8080 (ready immediately after boot)\n\nDocumentation: ${REPO_RAW_BASE}/README.md" \
            18 78
        CREATED_VMID=""
        return
    fi

    log_info "Starting VM ${VMID}..."
    if ! qm start "$VMID"; then
        die "Failed to start VM"
    fi
    log_info "VM started."

    whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "Installation Complete!" \
        --msgbox "✓ VM ${VMID} created and started successfully!\n\nThe VM is fully configured and the web UI is ready to use.\n\nTo find your VM's IP:\n  Proxmox UI → VM ${VMID} → Summary → IPs\n  or: qm guest cmd ${VMID} network-get-interfaces\n\nWeb UI: http://<VM_IP>:8080 (available immediately)\n\nDocumentation: ${REPO_RAW_BASE}/README.md" \
        18 78

    log_info "================================================================"
    log_info "Installation complete!"
    log_info "VM ID: ${VMID}"
    log_info "Find VM IP: Proxmox UI → VM ${VMID} → Summary → IPs"
    log_info "Web UI: http://<VM_IP>:8080 (ready now)"
    log_info "================================================================"
    CREATED_VMID=""
}

# ============================================================================
# Main
# ============================================================================

main() {
    log_info "phev2mqtt Proxmox Installer v${SCRIPT_VERSION}"
    log_info "================================================================"

    check_root
    check_proxmox
    check_dependencies

    TEMP_DIR=$(mktemp -d)
    log_info "Temp directory: ${TEMP_DIR}"

    show_welcome
    select_mode

    if [[ "$MODE" == "Advanced" ]]; then
        advanced_settings
        # VMID already set inside advanced_settings
        select_storage
    else
        default_settings
        select_vmid
        select_storage
    fi

    # SSH password always set in both modes
    select_ssh_password

    # USB adapter always shown in both modes
    select_usb_adapter

    # Simple mode gets explicit confirmation dialog
    # Advanced mode already confirmed via Do-Over dialog
    if [[ "$MODE" == "Simple" ]]; then
        show_confirmation
    fi

    create_vm
    start_vm

    log_info "Done!"
}

main "$@"
