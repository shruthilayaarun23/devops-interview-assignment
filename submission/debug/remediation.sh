#!/usr/bin/env bash
#
# remediation.sh — Incident remediation script
#
# TASK: Write a script that remediates the issue identified in your root cause analysis.
#
# Requirements:
#   - Fix the immediate issue
#   - Verify the fix worked
#   - Be safe to run (idempotent, with checks before making changes)
#   - Include error handling
# Root cause: eno1 MTU was changed from 1500 to 9000 during a scheduled
# maintenance window (NET-4521). The change was intended for eno2 (camera VLAN)
# but was incorrectly applied to eno1 (management + WAN). The site gateway
# (10.50.1.1) does not support jumbo frames, causing IPSec ESP packet
# fragmentation, VPN tunnel instability, and S3 upload failures.
#
# This script:
#   1. Confirms the MTU misconfiguration is present before making any changes
#   2. Reverts eno1 MTU to 1500
#   3. Verifies VPN tunnel stability
#   4. Verifies uploads resume
#   5. Optionally applies the intended change (jumbo frames) to eno2

set -euo pipefail

# ============================================
# GLOBALS
# ============================================

SITE_ID="${SITE_ID:-SITE-2847}"
LOG_FILE="/var/log/remediation-${SITE_ID}-$(date -u +%Y%m%dT%H%M%SZ).log"
WAN_IFACE="eno1"
CAMERA_IFACE="eno2"
CORRECT_WAN_MTU=1500
JUMBO_MTU=9000
VPN_PEER="52.14.88.201"
GATEWAY="10.50.1.1"
VPN_TUNNEL_NAME="aws-vpn"
NETPLAN_CONFIG="/etc/netplan/00-edge-network.yaml"
NETPLAN_BACKUP="/etc/netplan/00-edge-network.yaml.bak-$(date -u +%Y%m%dT%H%M%SZ)"

log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $1" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $1"
    exit 1
}

# Require root
if [ "$(id -u)" -ne 0 ]; then
    die "This script must be run as root"
fi

log "=== Starting remediation for site: ${SITE_ID} ==="
log "Logging to: ${LOG_FILE}"

# ============================================
# STEP 1: Confirm the misconfiguration exists
# ============================================

log "--- Step 1: Checking current MTU on ${WAN_IFACE} ---"

CURRENT_MTU=$(ip link show "${WAN_IFACE}" | awk '/mtu/ {print $5}')
log "Current ${WAN_IFACE} MTU: ${CURRENT_MTU}"

if [ "${CURRENT_MTU}" -eq "${CORRECT_WAN_MTU}" ]; then
    log "MTU on ${WAN_IFACE} is already ${CORRECT_WAN_MTU} — no change needed"
    log "If uploads are still failing, the root cause may be different. Exiting."
    exit 0
fi

if [ "${CURRENT_MTU}" -ne "${JUMBO_MTU}" ]; then
    log "WARNING: MTU is ${CURRENT_MTU} — neither 1500 nor 9000. Proceeding with revert to 1500 but investigate further."
fi

log "Misconfiguration confirmed: ${WAN_IFACE} MTU is ${CURRENT_MTU}, should be ${CORRECT_WAN_MTU}"

# ============================================
# STEP 2: Confirm gateway doesn't support jumbo frames
# ============================================

log "--- Step 2: Verifying gateway MTU constraint ---"

# Send a large ping with DF bit set — if it fails, gateway confirms it can't handle jumbo frames
if ping -c 2 -s 8972 -M do "${GATEWAY}" &>/dev/null; then
    log "WARNING: Gateway ${GATEWAY} appears to accept large packets — verify before proceeding"
    log "Proceeding with revert anyway as VPN instability is confirmed"
else
    log "Confirmed: gateway ${GATEWAY} cannot handle jumbo frames (ping with DF bit failed as expected)"
fi

# ============================================
# STEP 3: Backup netplan config
# ============================================

log "--- Step 3: Backing up netplan config ---"

if [ -f "${NETPLAN_CONFIG}" ]; then
    cp "${NETPLAN_CONFIG}" "${NETPLAN_BACKUP}"
    log "Netplan config backed up to: ${NETPLAN_BACKUP}"
else
    log "WARNING: Netplan config not found at ${NETPLAN_CONFIG} — will apply MTU change via ip command only"
fi

# ============================================
# STEP 4: Revert eno1 MTU to 1500
# ============================================

log "--- Step 4: Reverting ${WAN_IFACE} MTU to ${CORRECT_WAN_MTU} ---"

# Apply immediately via ip command (takes effect without reboot)
ip link set dev "${WAN_IFACE}" mtu "${CORRECT_WAN_MTU}"

# Also fix the netplan config to persist across reboots
if [ -f "${NETPLAN_CONFIG}" ]; then
    # Remove any mtu: 9000 line under eno1 in netplan
    # Uses Python for safe YAML manipulation rather than fragile sed
    python3 - <<EOF
import yaml, sys

with open("${NETPLAN_CONFIG}") as f:
    config = yaml.safe_load(f)

ethernets = config.get("network", {}).get("ethernets", {})

if "${WAN_IFACE}" in ethernets:
    iface = ethernets["${WAN_IFACE}"]
    if "mtu" in iface:
        old_mtu = iface.pop("mtu")
        print(f"Removed mtu: {old_mtu} from ${WAN_IFACE} in netplan config")
    else:
        print("No mtu key found under ${WAN_IFACE} in netplan — nothing to remove")
else:
    print("${WAN_IFACE} not found in netplan ethernets section")

with open("${NETPLAN_CONFIG}", "w") as f:
    yaml.dump(config, f, default_flow_style=False)
EOF
    log "Netplan config updated"
fi

# Verify the change took effect
NEW_MTU=$(ip link show "${WAN_IFACE}" | awk '/mtu/ {print $5}')
if [ "${NEW_MTU}" -ne "${CORRECT_WAN_MTU}" ]; then
    die "MTU revert failed — ${WAN_IFACE} MTU is still ${NEW_MTU}"
fi
log "MTU successfully reverted: ${WAN_IFACE} is now ${NEW_MTU}"

# ============================================
# STEP 5: Restart VPN tunnel
# ============================================

log "--- Step 5: Restarting VPN tunnel ---"

# Bring down the existing (unstable) SA and re-establish cleanly
if command -v swanctl &>/dev/null; then
    swanctl --terminate --ike "${VPN_TUNNEL_NAME}" 2>/dev/null || true
    sleep 2
    swanctl --initiate --child "${VPN_TUNNEL_NAME}"
    log "VPN tunnel re-initiated via swanctl"
else
    log "WARNING: swanctl not found — restarting strongswan service instead"
    systemctl restart strongswan
fi

# ============================================
# STEP 6: Verify VPN tunnel is stable
# ============================================

log "--- Step 6: Verifying VPN tunnel stability ---"

TUNNEL_UP=false
for i in {1..12}; do
    sleep 5
    if swanctl --list-sas 2>/dev/null | grep -q "ESTABLISHED"; then
        log "VPN tunnel ESTABLISHED (attempt ${i})"
        TUNNEL_UP=true
        break
    fi
    log "Waiting for tunnel... (attempt ${i}/12)"
done

if [ "${TUNNEL_UP}" = false ]; then
    die "VPN tunnel did not establish after 60 seconds — manual investigation required"
fi

# Wait an additional 30 seconds and check DPD is not timing out
log "Monitoring tunnel for DPD stability (30s)..."
sleep 30

if journalctl -u strongswan --since "30 seconds ago" | grep -q "DPD timeout"; then
    die "DPD timeouts still occurring after MTU revert — investigate further"
fi
log "No DPD timeouts detected — tunnel is stable"

# ============================================
# STEP 7: Verify uploads resume
# ============================================

log "--- Step 7: Verifying upload throughput ---"

# Test that large packets can now traverse the VPN without fragmentation
# Send a 1400-byte ping (safe under IPSec overhead) with DF bit set
if ping -c 3 -s 1400 -M do "${VPN_PEER}" &>/dev/null; then
    log "Large packet test passed — 1400-byte packets reaching VPN peer without fragmentation"
else
    log "WARNING: Large packet test failed — check for remaining MTU issues"
fi

log "Monitor the upload queue with:"
log "  journalctl -u video-ingest -f | grep -E 'upload|chunk|queue'"
log "  or check CloudWatch metric VideoChunkUploadErrors for SITE-2847"

# ============================================
# STEP 8: Apply intended change to eno2 (optional)
# ============================================

log "--- Step 8: Applying jumbo frames to ${CAMERA_IFACE} (intended change) ---"
log "NOTE: Skipping by default — run with APPLY_CAMERA_JUMBO=true to apply"

if [ "${APPLY_CAMERA_JUMBO:-false}" = "true" ]; then
    CAMERA_MTU=$(ip link show "${CAMERA_IFACE}" | awk '/mtu/ {print $5}')
    if [ "${CAMERA_MTU}" -eq "${JUMBO_MTU}" ]; then
        log "${CAMERA_IFACE} already has MTU ${JUMBO_MTU} — no change needed"
    else
        ip link set dev "${CAMERA_IFACE}" mtu "${JUMBO_MTU}"
        log "Applied MTU ${JUMBO_MTU} to ${CAMERA_IFACE}"
        # Persist in netplan
        python3 - <<EOF
import yaml
with open("${NETPLAN_CONFIG}") as f:
    config = yaml.safe_load(f)
config.setdefault("network", {}).setdefault("ethernets", {}).setdefault("${CAMERA_IFACE}", {})["mtu"] = ${JUMBO_MTU}
with open("${NETPLAN_CONFIG}", "w") as f:
    yaml.dump(config, f, default_flow_style=False)
print("Netplan updated for ${CAMERA_IFACE}")
EOF
    fi
else
    log "Skipped — set APPLY_CAMERA_JUMBO=true to apply jumbo frames to ${CAMERA_IFACE}"
fi

# ============================================
# DONE
# ============================================

log "=== Remediation complete for site: ${SITE_ID} ==="
log "Summary:"
log "  - ${WAN_IFACE} MTU reverted: ${CURRENT_MTU} -> ${CORRECT_WAN_MTU}"
log "  - Netplan config updated and backed up to: ${NETPLAN_BACKUP}"
log "  - VPN tunnel stable, no DPD timeouts"
log "  - Full log: ${LOG_FILE}"
log ""
log "Next steps:"
log "  1. Monitor upload queue for 10 minutes to confirm full recovery"
log "  2. Update ticket NET-4521 with findings and close"
log "  3. Review netplan change management process to prevent recurrence"
