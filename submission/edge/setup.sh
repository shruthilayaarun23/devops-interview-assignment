#!/usr/bin/env bash
#
# setup.sh — Edge device provisioning script
#
# TASK: Implement a provisioning script for a new edge device.
# Reference data/site_spec.json for hardware and requirements.
#
# Requirements:
#   - Error handling (set -euo pipefail, trap for cleanup)
#   - Docker installation and configuration
#   - NTP configuration for time synchronization
#   - Log rotation setup
#   - Systemd service for the video ingest container
#   - GPU driver setup (NVIDIA)
#   - Basic security hardening

set -euo pipefail

SITE_ID="${SITE_ID:-SITE-UNKNOWN}"
LOG_FILE="/var/log/edge-setup-${SITE_ID}.log"
SERVICE_USER="video-ingest"
VIDEO_BUFFER_DIR="/var/video-buffer"
NTP_SERVER="10.50.1.10"           # From site_spec.json
UPLOAD_LIMIT_MBPS=50              # From site_spec.json requirements
CAMERA_VLAN_IFACE="eno2"         # From site_spec.json edge_device.nics
MGMT_IFACE="eno1"                # From site_spec.json edge_device.nics
NVIDIA_DRIVER_VERSION="535"      # LTS driver, compatible with T4 + Ubuntu 22.04

log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $1" | tee -a "$LOG_FILE"
}

# Cleanup trap — logs failure line and ensures partial state is visible
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log "ERROR: Setup failed at line ${BASH_LINENO[0]} with exit code ${exit_code}"
        log "Check ${LOG_FILE} for details"
    fi
}
trap cleanup EXIT

# Require root
if [ "$(id -u)" -ne 0 ]; then
    log "ERROR: This script must be run as root"
    exit 1
fi

log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $1" | tee -a "$LOG_FILE"
}

log "Starting edge device setup for site: $SITE_ID"

# ============================================
# SECTION 1: System Updates and Base Packages
# ============================================
# TODO: Update system packages, install prerequisites
log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

log "Installing base packages..."
apt-get install -y -qq \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    ufw \
    fail2ban \
    logrotate \
    chrony \
    htop \
    jq \
    awscli \
    nvme-cli \
    net-tools

# ============================================
# SECTION 2: Docker Installation
# ============================================
# TODO: Install Docker CE, configure daemon (log driver, storage driver)
# TODO: Add the service user to the docker group
log "Installing Docker CE..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

log "Configuring Docker daemon..."
cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "5"
  },
  "storage-driver": "overlay2",
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  },
  "live-restore": true
}
EOF

# Create service user for video ingest — no login shell, no home dir
if ! id "${SERVICE_USER}" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "${SERVICE_USER}"
    log "Created service user: ${SERVICE_USER}"
fi
usermod -aG docker "${SERVICE_USER}"

systemctl enable docker
systemctl restart docker
log "Docker installed and configured"

# ============================================
# SECTION 3: NVIDIA GPU Drivers and Container Toolkit
# ============================================
# TODO: Install NVIDIA drivers and nvidia-container-toolkit
# TODO: Configure Docker to use the NVIDIA runtime
log "Installing NVIDIA drivers (version ${NVIDIA_DRIVER_VERSION})..."
apt-get install -y -qq \
    "nvidia-driver-${NVIDIA_DRIVER_VERSION}" \
    "nvidia-utils-${NVIDIA_DRIVER_VERSION}"

log "Installing NVIDIA Container Toolkit..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update -qq
apt-get install -y -qq nvidia-container-toolkit

nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

log "NVIDIA drivers and container toolkit installed"

# ============================================
# SECTION 4: NTP Configuration
# ============================================
# TODO: Configure NTP to use the site's NTP server
# Hint: See data/site_spec.json for the NTP server address
log "Configuring NTP (server: ${NTP_SERVER})..."

# Replace default NTP pools with site NTP server from site_spec.json
cat > /etc/chrony.conf <<EOF
# Site NTP server — SITE-2847 Denver
server ${NTP_SERVER} iburst prefer

# Fallback to public pool if site server unreachable
pool 2.ubuntu.pool.ntp.org iburst

# Allow significant time jumps on first sync (edge device may drift during shipping)
makestep 1.0 3

# Record drift
driftfile /var/lib/chrony/drift

# Log
logdir /var/log/chrony
EOF

systemctl enable chrony
systemctl restart chrony

# Wait for initial sync
log "Waiting for NTP sync..."
for i in {1..12}; do
    if chronyc tracking | grep -q "Leap status.*Normal"; then
        log "NTP synchronised"
        break
    fi
    sleep 5
done

# ============================================
# SECTION 5: Log Rotation
# ============================================
# TODO: Configure logrotate for application and Docker logs
log "Configuring log rotation..."

cat > /etc/logrotate.d/video-ingest <<EOF
# Video ingest application logs
/var/log/video-ingest/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 ${SERVICE_USER} ${SERVICE_USER}
    postrotate
        systemctl kill --signal=HUP video-ingest.service 2>/dev/null || true
    endscript
}
EOF

cat > /etc/logrotate.d/edge-setup <<EOF
# Edge provisioning logs
/var/log/edge-setup-*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF

# Docker log rotation is handled via daemon.json (max-size + max-file above)
log "Log rotation configured"

# ============================================
# SECTION 6: Systemd Service
# ============================================
# TODO: Create a systemd service that runs the video-ingest container
# Requirements:
#   - Restart on failure
#   - Start after Docker
#   - GPU access
#   - Mount local storage for video buffer
log "Creating video buffer directory..."
mkdir -p "${VIDEO_BUFFER_DIR}"
chown "${SERVICE_USER}:${SERVICE_USER}" "${VIDEO_BUFFER_DIR}"
chmod 750 "${VIDEO_BUFFER_DIR}"

log "Creating video-ingest systemd service..."

cat > /etc/systemd/system/video-ingest.service <<EOF
[Unit]
Description=Video Ingest Service — SITE-2847
Documentation=https://internal.vlt.io/docs/edge
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
Restart=on-failure
RestartSec=10s
StartLimitIntervalSec=120
StartLimitBurst=5

# Pull latest approved image before starting
ExecStartPre=/usr/bin/docker pull \
    123456789012.dkr.ecr.us-east-1.amazonaws.com/video-ingest:stable

ExecStart=/usr/bin/docker run --rm \
    --name video-ingest \
    --runtime nvidia \
    --gpus all \
    --network host \
    --restart no \
    --env SITE_ID=${SITE_ID} \
    --env CAMERA_VLAN_IFACE=${CAMERA_VLAN_IFACE} \
    --env UPLOAD_LIMIT_MBPS=${UPLOAD_LIMIT_MBPS} \
    --env AWS_REGION=us-east-1 \
    --volume ${VIDEO_BUFFER_DIR}:/var/video-buffer \
    --volume /var/log/video-ingest:/var/log/app \
    --read-only \
    --tmpfs /tmp:size=512m \
    123456789012.dkr.ecr.us-east-1.amazonaws.com/video-ingest:stable

ExecStop=/usr/bin/docker stop video-ingest

# Allow time for in-flight chunk uploads to complete before hard kill
TimeoutStopSec=30

StandardOutput=journal
StandardError=journal
SyslogIdentifier=video-ingest

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /var/log/video-ingest
chown "${SERVICE_USER}:${SERVICE_USER}" /var/log/video-ingest

systemctl daemon-reload
systemctl enable video-ingest.service
log "video-ingest systemd service created and enabled"

# ============================================
# SECTION 7: Security Hardening
# ============================================
# TODO: Basic security (disable root SSH, configure UFW, etc.)
log "Applying security hardening..."

# --- SSH hardening ---
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
# Disable root login
PermitRootLogin no

# Key-based auth only — no passwords
PasswordAuthentication no
PubkeyAuthentication yes

# Limit SSH to management VLAN interface only
ListenAddress 10.50.1.0

# Restrict to management VLAN subnet (enforced at UFW level too)
AllowUsers *@10.50.1.0/24

# Reduce attack surface
X11Forwarding no
AllowTcpForwarding no
MaxAuthTries 3
LoginGraceTime 30
EOF

systemctl restart ssh

# --- UFW firewall ---
log "Configuring UFW..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH from management VLAN only
ufw allow in on "${MGMT_IFACE}" to any port 22 proto tcp comment "SSH from management VLAN"

# Prometheus metrics scraping from management VLAN
ufw allow in on "${MGMT_IFACE}" to any port 9090 proto tcp comment "Prometheus"
ufw allow in on "${MGMT_IFACE}" to any port 3000 proto tcp comment "Grafana"

# RTSP from camera VLAN only — no camera traffic on management interface
ufw allow in on "${CAMERA_VLAN_IFACE}" to any port 554 proto tcp comment "RTSP from camera VLAN"

# Allow VPN tunnel (IPSec)
ufw allow in on "${MGMT_IFACE}" to any port 500 proto udp comment "IPSec IKE"
ufw allow in on "${MGMT_IFACE}" to any port 4500 proto udp comment "IPSec NAT-T"

ufw --force enable
log "UFW configured"

# --- fail2ban ---
cat > /etc/fail2ban/jail.d/sshd.conf <<EOF
[sshd]
enabled = true
port    = ssh
filter  = sshd
maxretry = 3
bantime  = 3600
findtime = 600
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# --- Kernel hardening via sysctl ---
cat > /etc/sysctl.d/99-edge-hardening.conf <<EOF
# Disable IP forwarding (edge device is not a router)
net.ipv4.ip_forward = 0

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Ignore source-routed packets
net.ipv4.conf.all.accept_source_route = 0

# Log martian packets
net.ipv4.conf.all.log_martians = 1

# Protect against SYN flood
net.ipv4.tcp_syncookies = 1
EOF

sysctl --system

log "Security hardening complete"

log "Edge device setup complete for site: $SITE_ID"
