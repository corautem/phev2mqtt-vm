#!/usr/bin/env bash
#
# phev2mqtt VM Setup Script
# Runs inside the Debian 12 VM on first boot via cloud-init
#
# This script installs all dependencies, builds phev2mqtt from source,
# sets up the web UI, and configures all services.
#

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

PHEV2MQTT_REPO="https://github.com/buxtronix/phev2mqtt.git"
PHEV2MQTT_BINARY="/usr/local/bin/phev2mqtt"
DKMS_DRIVER_REPO="https://github.com/morrownr/88x2bu-20210702.git"
DKMS_DRIVER_NAME="88x2bu"

WEBUI_DIR="/opt/phev2mqtt-webui"
CONFIG_DIR="/etc/phev2mqtt-webui"
LOG_DIR="/var/log/phev2mqtt-webui"

# Cloud-init user-data script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Status file to track completion and make idempotent
STATUS_FILE="/var/lib/phev2mqtt-setup-status"

# Colors
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

die() {
    log_error "$*"
    exit 1
}

# Check if a step has been completed (idempotency)
is_completed() {
    local step="$1"
    grep -qx "$step" "$STATUS_FILE" 2>/dev/null
}

# Mark a step as completed
mark_completed() {
    local step="$1"
    echo "$step" >> "$STATUS_FILE"
}

# ============================================================================
# Setup Steps
# ============================================================================

step_update_system() {
    if is_completed "update_system"; then
        log_info "System update already completed, skipping"
        return
    fi
    
    log_info "Updating package lists..."
    apt-get update -qq
    
    log_info "Installing base dependencies..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git \
        build-essential \
        curl \
        wget \
        usbutils \
        dkms \
        bc \
        python3 \
        python3-pip \
        python3-venv \
        qemu-guest-agent \
        linux-headers-$(uname -r) \
        || die "Failed to install base dependencies"
    
    log_info "Enabling QEMU guest agent..."
    systemctl enable qemu-guest-agent
    systemctl start qemu-guest-agent
    
    mark_completed "update_system"
}

step_configure_ssh() {
    if is_completed "configure_ssh"; then
        log_info "SSH configuration already completed, skipping"
        return
    fi
    
    log_info "Configuring SSH access..."
    
    # Install openssh-server if not present
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server || die "Failed to install openssh-server"
    
    # Configure SSH to allow root login with password
    log_info "Enabling root login with password..."
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    
    # Enable and start SSH service
    systemctl enable ssh
    systemctl start ssh || log_warn "SSH start failed - will be available after reboot"
    
    mark_completed "configure_ssh"
    log_info "SSH configured - root login enabled with password set at install time"
}

step_detect_usb_adapter() {
    if is_completed "detect_usb_adapter"; then
        log_info "USB adapter detection already completed, skipping"
        return
    fi
    
    log_info "Detecting USB WiFi adapter..."
    
    # Wait for USB devices to be available (cloud-init timing)
    sleep 5
    
    local usb_devices
    usb_devices=$(lsusb | grep -v "Linux Foundation" || true)
    
    if [[ -z "$usb_devices" ]]; then
        log_warn "No USB devices detected yet - adapter may not be passed through"
    else
        log_info "USB devices detected:"
        echo "$usb_devices"
    fi
    
    mark_completed "detect_usb_adapter"
}

step_install_wifi_driver() {
    if is_completed "install_wifi_driver"; then
        log_info "WiFi driver already installed, skipping"
        return
    fi
    
    log_info "Installing WiFi driver (${DKMS_DRIVER_NAME}) via DKMS..."
    
    local driver_version
    local temp_clone_dir="/tmp/88x2bu-src"
    rm -rf "$temp_clone_dir"
    git clone "$DKMS_DRIVER_REPO" "$temp_clone_dir" || die "Failed to clone driver repository"
    driver_version=$(grep -oP '^PACKAGE_VERSION="\K[^"]+' "$temp_clone_dir/dkms.conf" || echo "5.13.1")
    
    local dkms_src_dir="/usr/src/${DKMS_DRIVER_NAME}-${driver_version}"
    rm -rf "$dkms_src_dir"
    mkdir -p "$dkms_src_dir"
    cp -r "$temp_clone_dir/." "$dkms_src_dir/"
    rm -rf "$temp_clone_dir"
    
    log_info "Driver version: ${driver_version}"
    
    cd "$dkms_src_dir"
    
    # Run DKMS commands explicitly (non-interactive)
    log_info "Adding DKMS module..."
    dkms add "${DKMS_DRIVER_NAME}/${driver_version}" || log_warn "DKMS add failed (may already be added)"
    
    log_info "Building DKMS module..."
    if ! dkms build "${DKMS_DRIVER_NAME}/${driver_version}"; then
        log_warn "DKMS build failed - WiFi driver not loaded. Install manually after boot."
        mark_completed "install_wifi_driver"
        return
    fi
    
    log_info "Installing DKMS module..."
    dkms install "${DKMS_DRIVER_NAME}/${driver_version}" || {
        log_warn "DKMS install failed - WiFi driver not loaded. Install manually after boot."
        mark_completed "install_wifi_driver"
        return
    }
    
    # Verify driver module exists
    if modinfo "$DKMS_DRIVER_NAME" &>/dev/null; then
        log_info "WiFi driver ${DKMS_DRIVER_NAME} installed successfully"
    else
        log_warn "WiFi driver module not found - may need manual intervention"
    fi
    
    mark_completed "install_wifi_driver"
}

step_install_go() {
    if is_completed "install_go"; then
        log_info "Go already installed, skipping"
        return
    fi
    
    log_info "Installing Go compiler..."
    
    # Detect architecture
    local arch
    arch=$(uname -m)
    
    local go_arch
    case "$arch" in
        x86_64)
            go_arch="amd64"
            ;;
        aarch64)
            go_arch="arm64"
            ;;
        armv7l)
            go_arch="armv6l"
            ;;
        *)
            die "Unsupported architecture: $arch"
            ;;
    esac
    
    # Fetch latest Go version dynamically
    log_info "Fetching latest Go version..."
    local go_version
    go_version=$(curl -fsSL https://go.dev/VERSION?m=text | head -1)
    
    if [[ -z "$go_version" ]]; then
        die "Failed to fetch Go version"
    fi
    
    log_info "Latest Go version: ${go_version}"
    
    local go_tarball="${go_version}.linux-${go_arch}.tar.gz"
    local go_url="https://go.dev/dl/${go_tarball}"
    
    log_info "Downloading Go ${go_version} for ${go_arch}..."
    wget -q --show-progress "$go_url" -O "/tmp/${go_tarball}" || die "Failed to download Go"
    
    # Extract to /usr/local
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/${go_tarball}" || die "Failed to extract Go"
    rm "/tmp/${go_tarball}"
    
    # Add to PATH for this script and system-wide
    export PATH=$PATH:/usr/local/go/bin
    export GOPATH=/root/go
    export GOMODCACHE=/root/go/pkg/mod
    export GOCACHE=/root/.cache/go-build
    mkdir -p "$GOPATH" "$GOMODCACHE" "$GOCACHE"
    echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
    
    # Verify installation
    if /usr/local/go/bin/go version; then
        log_info "Go installed successfully"
    else
        die "Go installation verification failed"
    fi
    
    mark_completed "install_go"
}

step_build_phev2mqtt() {
    if is_completed "build_phev2mqtt"; then
        log_info "phev2mqtt already built, skipping"
        return
    fi
    
    log_info "Building phev2mqtt from source..."
    
    # Clone repository
    local build_dir="/tmp/phev2mqtt-build"
    rm -rf "$build_dir"
    git clone "$PHEV2MQTT_REPO" "$build_dir" || die "Failed to clone phev2mqtt repository"
    
    cd "$build_dir"
    
    # Build binary
    export PATH=$PATH:/usr/local/go/bin
    export GOPATH=/root/go
    export GOMODCACHE=/root/go/pkg/mod
    export GOCACHE=/root/.cache/go-build
    mkdir -p "$GOPATH" "$GOMODCACHE" "$GOCACHE"
    /usr/local/go/bin/go build -o phev2mqtt || die "Failed to build phev2mqtt — check GOPATH and network connectivity"
    
    # Verify binary exists
    if [[ ! -f "./phev2mqtt" ]]; then
        die "phev2mqtt binary not found after build"
    fi
    
    # Copy to canonical location
    cp ./phev2mqtt "$PHEV2MQTT_BINARY" || die "Failed to copy binary to ${PHEV2MQTT_BINARY}"
    chmod +x "$PHEV2MQTT_BINARY"
    
    # Verify binary is executable
    [[ -x "$PHEV2MQTT_BINARY" ]] || die "Binary not executable"
    
    log_info "phev2mqtt binary installed successfully at ${PHEV2MQTT_BINARY}"
    
    # Cleanup
    rm -rf "$build_dir"
    
    mark_completed "build_phev2mqtt"
}

step_install_webui() {
    if is_completed "install_webui"; then
        log_info "Web UI already installed, skipping"
        return
    fi
    
    log_info "Installing phev2mqtt web UI..."
    
    # Create directories
    mkdir -p "$WEBUI_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$LOG_DIR"
    
    # Copy web UI files from repository (assumes this script is in repo root)
    # In production, this would be downloaded from GitHub or bundled
    local repo_webui_dir="${SCRIPT_DIR}/webui"
    
    if [[ -d "$repo_webui_dir" ]]; then
        log_info "Copying web UI files from repository..."
        cp -r "$repo_webui_dir"/* "$WEBUI_DIR/" || die "Failed to copy web UI files"
    else
        log_warn "Web UI source directory not found at ${repo_webui_dir}, attempting download..."
        
        # Download from GitHub
        local webui_archive_url="https://github.com/corautem/phev2mqtt-vm/archive/refs/heads/main.tar.gz"
        wget -q "$webui_archive_url" -O /tmp/phev2mqtt-webui.tar.gz || die "Failed to download web UI"
        
        tar -xzf /tmp/phev2mqtt-webui.tar.gz -C /tmp/ || die "Failed to extract web UI"
        
        # Find and copy webui directory
        local extracted_dir
        extracted_dir=$(find /tmp -name "phev2mqtt-vm-*" -type d | head -n1)
        log_info "Extracted archive contents:"
        ls -la "${extracted_dir}/" || true
        if [[ -d "${extracted_dir}/webui" ]]; then
            log_info "Webui directory contents:"
            ls -la "${extracted_dir}/webui/" || true
            cp -r "${extracted_dir}/webui"/* "$WEBUI_DIR/" || die "Failed to copy web UI files"
            if [[ ! -f "${WEBUI_DIR}/requirements.txt" ]]; then
                die "Copy failed — requirements.txt missing from ${WEBUI_DIR}"
            fi
        else
            die "Could not find webui directory in downloaded archive"
        fi
        
        rm -rf /tmp/phev2mqtt-webui.tar.gz "$extracted_dir"
    fi
    
    # Ensure PATH and environment are set for cloud-init restricted context
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export TMPDIR=/var/tmp
    export HOME=/root
    export XDG_CACHE_HOME=/var/tmp/pip-cache
    mkdir -p /var/tmp /root /var/tmp/pip-cache

    # Create Python virtual environment
    log_info "Creating Python virtual environment..."
    python3 -m venv "${WEBUI_DIR}/venv" || die "Failed to create virtual environment"
    
    # Install Python dependencies
    log_info "Installing Python dependencies..."
    if [[ ! -f "${WEBUI_DIR}/requirements.txt" ]]; then
        die "requirements.txt not found at ${WEBUI_DIR}/requirements.txt"
    fi
    "${WEBUI_DIR}/venv/bin/python3" -m pip install --no-cache-dir --upgrade pip
    "${WEBUI_DIR}/venv/bin/python3" -m pip install --no-cache-dir -r "${WEBUI_DIR}/requirements.txt" \
        || die "Failed to install Python dependencies"
    
    # Set permissions
    chown -R root:root "$WEBUI_DIR"
    chmod -R 755 "$WEBUI_DIR"
    chmod 700 "$CONFIG_DIR"
    
    mark_completed "install_webui"
}

step_configure_journald() {
    if is_completed "configure_journald"; then
        log_info "journald already configured, skipping"
        return
    fi
    
    log_info "Configuring journald limits..."
    
    local journald_conf="/etc/systemd/journald.conf.d/phev2mqtt.conf"
    mkdir -p "$(dirname "$journald_conf")"
    
    # Copy from repository or create
    local repo_journald="${SCRIPT_DIR}/config/journald.conf"
    if [[ -f "$repo_journald" ]]; then
        cp "$repo_journald" "$journald_conf"
    else
        cat > "$journald_conf" <<'EOF'
# journald limits for phev2mqtt

[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
MaxRetentionSec=7day
SystemKeepFree=500M
EOF
    fi
    
    # Restart journald to apply
    systemctl restart systemd-journald || log_warn "Failed to restart journald"
    
    mark_completed "configure_journald"
}

step_configure_logrotate() {
    if is_completed "configure_logrotate"; then
        log_info "logrotate already configured, skipping"
        return
    fi
    
    log_info "Configuring logrotate..."
    
    local logrotate_conf="/etc/logrotate.d/phev2mqtt-webui"
    
    # Copy from repository or create
    local repo_logrotate="${SCRIPT_DIR}/config/logrotate.phev2mqtt-webui"
    if [[ -f "$repo_logrotate" ]]; then
        cp "$repo_logrotate" "$logrotate_conf"
    else
        cat > "$logrotate_conf" <<'EOF'
/var/log/phev2mqtt-webui/*.log {
    size 20M
    rotate 5
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
    postrotate
        systemctl kill -s HUP phev2mqtt-webui.service
    endscript
}
EOF
    fi
    
    mark_completed "configure_logrotate"
}

step_install_systemd_services() {
    if is_completed "install_systemd_services"; then
        log_info "systemd services already installed, skipping"
        return
    fi
    
    log_info "Installing systemd service units..."
    
    # phev2mqtt service
    local phev_service="/etc/systemd/system/phev2mqtt.service"
    local repo_phev_service="${SCRIPT_DIR}/systemd/phev2mqtt.service"
    
    if [[ -f "$repo_phev_service" ]]; then
        cp "$repo_phev_service" "$phev_service"
    else
        # Minimal placeholder unit — real service managed by web UI after MQTT config
        cat > "$phev_service" <<'EOF'
[Unit]
Description=phev2mqtt service (not configured)
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/echo "phev2mqtt not configured - configure via web UI"
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
    fi
    
    # Create empty environment file
    touch /etc/phev2mqtt-webui/phev2mqtt.env
    chmod 600 /etc/phev2mqtt-webui/phev2mqtt.env
    
    # Web UI service
    local webui_service="/etc/systemd/system/phev2mqtt-webui.service"
    local repo_webui_service="${SCRIPT_DIR}/systemd/phev2mqtt-webui.service"
    
    if [[ -f "$repo_webui_service" ]]; then
        cp "$repo_webui_service" "$webui_service"
    else
        cat > "$webui_service" <<'EOF'
[Unit]
Description=phev2mqtt Web UI
After=network.target phev2mqtt.service
Wants=phev2mqtt.service

[Service]
Type=simple
WorkingDirectory=/opt/phev2mqtt-webui
EnvironmentFile=-/etc/phev2mqtt-webui/webui.env
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/phev2mqtt-webui/venv/bin/python /opt/phev2mqtt-webui/app.py
Restart=always
RestartSec=10s
SyslogIdentifier=phev2mqtt-webui
StandardOutput=syslog
StandardError=syslog

[Install]
WantedBy=multi-user.target
EOF
    fi
    
    # Reload systemd
    systemctl daemon-reload
    
    mark_completed "install_systemd_services"
}

step_enable_services() {
    if is_completed "enable_services"; then
        log_info "Services already enabled, skipping"
        return
    fi
    
    log_info "Enabling systemd services..."
    
    # Enable web UI (it will be accessible immediately)
    systemctl enable phev2mqtt-webui.service || log_warn "Failed to enable phev2mqtt-webui service"
    
    # Do NOT enable phev2mqtt service — it requires MQTT config which is set via web UI
    # The web UI will start it after configuration
    
    # Start web UI now
    systemctl start phev2mqtt-webui.service || log_warn "Failed to start phev2mqtt-webui service"
    
    mark_completed "enable_services"
}

step_finalize() {
    if is_completed "finalize"; then
        log_info "Setup already finalized"
        return
    fi
    
    log_info "Finalizing setup..."
    
    # Get IP address
    local ip_addr
    ip_addr=$(hostname -I | awk '{print $1}')
    
    log_info "================================================================"
    log_info "phev2mqtt VM Setup Complete!"
    log_info "================================================================"
    log_info "VM IP Address: ${ip_addr}"
    log_info "Web UI: http://${ip_addr}:8080"
    log_info ""
    log_info "Next steps:"
    log_info "1. Open the web UI in your browser"
    log_info "2. Set your web UI password (mandatory first-run setup)"
    log_info "3. Configure WiFi connection to your vehicle"
    log_info "4. Configure MQTT broker connection"
    log_info "================================================================"
    
    mark_completed "finalize"
}

# ============================================================================
# Main
# ============================================================================

main() {
    log_info "Starting phev2mqtt VM setup..."
    log_info "================================================================"
    
    # Initialize status file
    touch "$STATUS_FILE"
    
    # Run setup steps
    step_update_system
    step_configure_ssh
    step_detect_usb_adapter
    step_install_wifi_driver
    step_install_go
    step_build_phev2mqtt
    step_install_webui
    step_configure_journald
    step_configure_logrotate
    step_install_systemd_services
    step_enable_services
    step_finalize
    
    log_info "Setup script completed successfully"
}

# Only run if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
