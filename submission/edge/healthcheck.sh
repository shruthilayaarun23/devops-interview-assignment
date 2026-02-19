#!/usr/bin/env bash
#
# healthcheck.sh — Edge device health check script
#
# TASK: Implement a health check script that verifies edge device status.
#
# Requirements:
#   - Check Docker daemon is running
#   - Check video-ingest container is running and healthy
#   - Check GPU is accessible (nvidia-smi)
#   - Check disk usage is below threshold
#   - Check NTP synchronization
#   - Check VPN tunnel is up
#   - Check camera connectivity (ping camera subnet)
#   - Output JSON status report
#   - Exit code 0 if healthy, 1 if degraded, 2 if critical

set -euo pipefail

# TODO: Implement health checks
# TODO: Output JSON report to stdout
# TODO: Set appropriate exit code

# ============================================
# GLOBALS
# ============================================

SITE_ID="${SITE_ID:-SITE-UNKNOWN}"
DISK_WARN_PCT=80
DISK_CRIT_PCT=90
VIDEO_BUFFER_DIR="/var/video-buffer"
CAMERA_SUBNET="10.50.20.0/24"   # Camera VLAN subnet — site_spec.json VLAN 20
VPN_ENDPOINT="vpn-0a1b2c3d4e5f.amazonaws.com"
NTP_SERVER="10.50.1.10"
CAMERA_IPS=("10.50.20.1" "10.50.20.2" "10.50.20.3" "10.50.20.4"
            "10.50.20.5" "10.50.20.6" "10.50.20.7" "10.50.20.8")

# Exit codes
EXIT_HEALTHY=0
EXIT_DEGRADED=1
EXIT_CRITICAL=2

# Collected results
STATUS="healthy"
CHECKS=()

# ============================================
# HELPERS
# ============================================

# Record a check result and escalate overall status if needed
# Usage: record_check "name" "status" "message"
record_check() {
    local name="$1"
    local check_status="$2"  # healthy | degraded | critical
    local message="$3"

    CHECKS+=("{\"check\":\"${name}\",\"status\":\"${check_status}\",\"message\":$(echo "${message}" | jq -Rs .)}")

    if [ "${check_status}" = "critical" ] && [ "${STATUS}" != "critical" ]; then
        STATUS="critical"
    elif [ "${check_status}" = "degraded" ] && [ "${STATUS}" = "healthy" ]; then
        STATUS="degraded"
    fi
}

# ============================================
# CHECK 1: Docker daemon
# ============================================

check_docker() {
    if systemctl is-active --quiet docker; then
        record_check "docker_daemon" "healthy" "Docker daemon is running"
    else
        record_check "docker_daemon" "critical" "Docker daemon is not running"
    fi
}

# ============================================
# CHECK 2: video-ingest container
# ============================================

check_container() {
    local container_state
    container_state=$(docker inspect --format '{{.State.Status}}' video-ingest 2>/dev/null || echo "not_found")

    if [ "${container_state}" = "running" ]; then
        # Check Docker healthcheck result if configured
        local health
        health=$(docker inspect --format '{{.State.Health.Status}}' video-ingest 2>/dev/null || echo "none")
        if [ "${health}" = "unhealthy" ]; then
            record_check "video_ingest_container" "degraded" "Container is running but health check reports unhealthy"
        else
            record_check "video_ingest_container" "healthy" "Container is running (health: ${health})"
        fi
    elif [ "${container_state}" = "not_found" ]; then
        record_check "video_ingest_container" "critical" "Container not found — service may not have started"
    else
        record_check "video_ingest_container" "critical" "Container is in state: ${container_state}"
    fi
}

# ============================================
# CHECK 3: GPU accessibility
# ============================================

check_gpu() {
    if ! command -v nvidia-smi &>/dev/null; then
        record_check "gpu" "critical" "nvidia-smi not found — drivers may not be installed"
        return
    fi

    local gpu_output
    if gpu_output=$(nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total \
                    --format=csv,noheader,nounits 2>&1); then
        local gpu_name temp util mem_used mem_total
        IFS=',' read -r gpu_name temp util mem_used mem_total <<< "${gpu_output}"
        gpu_name=$(echo "${gpu_name}" | xargs)
        temp=$(echo "${temp}" | xargs)

        if [ "${temp}" -gt 85 ]; then
            record_check "gpu" "critical" "GPU temperature critical: ${temp}°C (${gpu_name})"
        elif [ "${temp}" -gt 75 ]; then
            record_check "gpu" "degraded" "GPU temperature elevated: ${temp}°C (${gpu_name})"
        else
            record_check "gpu" "healthy" "GPU accessible: ${gpu_name}, temp: ${temp}°C, mem: ${mem_used}/${mem_total} MiB"
        fi
    else
        record_check "gpu" "critical" "nvidia-smi failed: ${gpu_output}"
    fi
}

# ============================================
# CHECK 4: Disk usage
# ============================================

check_disk() {
    # Check root filesystem
    local root_pct
    root_pct=$(df / --output=pcent | tail -1 | tr -d '% ')

    if [ "${root_pct}" -ge "${DISK_CRIT_PCT}" ]; then
        record_check "disk_root" "critical" "Root filesystem at ${root_pct}% (threshold: ${DISK_CRIT_PCT}%)"
    elif [ "${root_pct}" -ge "${DISK_WARN_PCT}" ]; then
        record_check "disk_root" "degraded" "Root filesystem at ${root_pct}% (threshold: ${DISK_WARN_PCT}%)"
    else
        record_check "disk_root" "healthy" "Root filesystem at ${root_pct}%"
    fi

    # Check video buffer directory separately — this fills fastest
    if [ -d "${VIDEO_BUFFER_DIR}" ]; then
        local buf_pct
        buf_pct=$(df "${VIDEO_BUFFER_DIR}" --output=pcent | tail -1 | tr -d '% ')

        if [ "${buf_pct}" -ge "${DISK_CRIT_PCT}" ]; then
            record_check "disk_video_buffer" "critical" "Video buffer at ${buf_pct}% — chunk uploads may be falling behind"
        elif [ "${buf_pct}" -ge "${DISK_WARN_PCT}" ]; then
            record_check "disk_video_buffer" "degraded" "Video buffer at ${buf_pct}%"
        else
            record_check "disk_video_buffer" "healthy" "Video buffer at ${buf_pct}%"
        fi
    fi
}

# ============================================
# CHECK 5: NTP synchronisation
# ============================================

check_ntp() {
    if ! command -v chronyc &>/dev/null; then
        record_check "ntp" "degraded" "chronyc not found — cannot verify time sync"
        return
    fi

    local tracking
    tracking=$(chronyc tracking 2>&1)

    if echo "${tracking}" | grep -q "Leap status.*Normal"; then
        local offset
        offset=$(echo "${tracking}" | grep "System time" | awk '{print $4, $5}')
        record_check "ntp" "healthy" "NTP synchronised to ${NTP_SERVER}, offset: ${offset}"
    elif echo "${tracking}" | grep -q "Not synchronised"; then
        record_check "ntp" "critical" "NTP not synchronised — time drift may affect video timestamps"
    else
        record_check "ntp" "degraded" "NTP status uncertain: $(echo "${tracking}" | grep 'Leap status')"
    fi
}

# ============================================
# CHECK 6: VPN tunnel
# ============================================

check_vpn() {
    # Check for active IPSec tunnel via strongSwan
    if command -v swanctl &>/dev/null; then
        local sa_output
        sa_output=$(swanctl --list-sas 2>&1)
        if echo "${sa_output}" | grep -q "ESTABLISHED"; then
            record_check "vpn" "healthy" "IPSec tunnel ESTABLISHED to ${VPN_ENDPOINT}"
        else
            record_check "vpn" "critical" "IPSec tunnel is not established — cloud upload and SQS events will fail"
        fi
    else
        # Fallback: check if we can reach the AWS VPC DNS (169.254.169.253 is unreachable without VPN)
        if ping -c 2 -W 2 169.254.169.253 &>/dev/null; then
            record_check "vpn" "healthy" "VPN reachable (swanctl not available, used ping fallback)"
        else
            record_check "vpn" "critical" "Cannot verify VPN — swanctl not found and AWS endpoint unreachable"
        fi
    fi
}

# ============================================
# CHECK 7: Camera connectivity
# ============================================

check_cameras() {
    local reachable=0
    local unreachable=0
    local unreachable_list=()

    for ip in "${CAMERA_IPS[@]}"; do
        if ping -c 1 -W 1 "${ip}" &>/dev/null; then
            (( reachable++ ))
        else
            (( unreachable++ ))
            unreachable_list+=("${ip}")
        fi
    done

    local total=${#CAMERA_IPS[@]}

    if [ "${unreachable}" -eq 0 ]; then
        record_check "cameras" "healthy" "All ${total} cameras reachable on camera VLAN"
    elif [ "${unreachable}" -ge "${total}" ]; then
        record_check "cameras" "critical" "No cameras reachable — camera VLAN may be down"
    else
        local unreachable_str
        unreachable_str=$(IFS=','; echo "${unreachable_list[*]}")
        record_check "cameras" "degraded" "${unreachable}/${total} cameras unreachable: ${unreachable_str}"
    fi
}

# ============================================
# RUN ALL CHECKS
# ============================================

check_docker
check_container
check_gpu
check_disk
check_ntp
check_vpn
check_cameras

# ============================================
# OUTPUT JSON REPORT
# ============================================

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
CHECKS_JSON=$(IFS=','; echo "${CHECKS[*]}")

cat <<EOF
{
  "site_id": "${SITE_ID}",
  "timestamp": "${TIMESTAMP}",
  "overall_status": "${STATUS}",
  "checks": [${CHECKS_JSON}]
}
EOF

# ============================================
# EXIT CODE
# ============================================

case "${STATUS}" in
    healthy)  exit ${EXIT_HEALTHY}  ;;
    degraded) exit ${EXIT_DEGRADED} ;;
    critical) exit ${EXIT_CRITICAL} ;;
    *)        exit ${EXIT_CRITICAL} ;;
esac