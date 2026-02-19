#!/usr/bin/env bash
#
# firewall_rules.sh — Edge device firewall configuration
#
# TASK: Implement iptables rules for the edge device.
# Reference data/site_spec.json for network details.
#
# Requirements:
#   - Default DROP policy on INPUT and FORWARD chains
#   - Allow RTSP (554/tcp, 554/udp) from camera VLAN only
#   - Allow HTTPS (443/tcp) outbound for S3 uploads and API calls
#   - Allow SSH (22/tcp) from management VLAN only
#   - Camera VLAN must not be able to reach management or corporate VLANs
#   - Allow established/related connections
#   - Allow loopback traffic
#   - Allow ICMP for diagnostics
#
# Hints:
#   - Camera VLAN: (define based on your site_plan.md)
#   - Management VLAN: 10.50.1.0/24
#   - Edge device interfaces: eno1 (mgmt/WAN), eno2 (camera VLAN)

# Network layout (from site_spec.json):
#   eno1  - management VLAN (10.50.1.0/24) + WAN uplink
#   eno2  - camera VLAN (10.50.20.0/24)
#   Corporate VLAN: 10.50.10.0/24
#   VPN peer: 52.14.88.201 (AWS)


set -euo pipefail

MGMT_VLAN="10.50.1.0/24"
CAMERA_VLAN="10.50.20.0/24"
CORPORATE_VLAN="10.50.10.0/24"
MGMT_IFACE="eno1"
CAMERA_IFACE="eno2"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $1"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must be run as root"
    exit 1
fi

log "Applying firewall rules for SITE-2847..."


# --- Flush existing rules ---
# TODO
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# --- Default policies ---
# TODO
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  ACCEPT

# --- Loopback ---
# TODO
iptables -A INPUT -i lo -j ACCEPT

# --- Established/Related ---
# TODO
iptables -A INPUT   -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# --- SSH from management VLAN only ---
# TODO
iptables -A INPUT -i "${MGMT_IFACE}" -s "${MGMT_VLAN}" -p tcp --dport 22 \
    -m conntrack --ctstate NEW -j ACCEPT

# --- RTSP from camera VLAN only ---
# TODO
iptables -A INPUT -i "${CAMERA_IFACE}" -s "${CAMERA_VLAN}" -p tcp --dport 554 \
    -m conntrack --ctstate NEW -j ACCEPT
iptables -A INPUT -i "${CAMERA_IFACE}" -s "${CAMERA_VLAN}" -p udp --dport 554 -j ACCEPT
# --- HTTPS outbound ---
# TODO
iptables -A INPUT -i "${CAMERA_IFACE}" -p tcp --dport 443 -j DROP
# --- Camera VLAN isolation (block camera-to-management/corporate) ---
# TODO
# Block camera VLAN from reaching management VLAN
iptables -A FORWARD -i "${CAMERA_IFACE}" -d "${MGMT_VLAN}"       -j DROP
# Block camera VLAN from reaching corporate VLAN
iptables -A FORWARD -i "${CAMERA_IFACE}" -d "${CORPORATE_VLAN}"  -j DROP
# Block camera VLAN from reaching any other RFC1918 space (catch-all)
iptables -A FORWARD -i "${CAMERA_IFACE}" -d 10.0.0.0/8           -j DROP
iptables -A FORWARD -i "${CAMERA_IFACE}" -d 172.16.0.0/12        -j DROP
iptables -A FORWARD -i "${CAMERA_IFACE}" -d 192.168.0.0/16       -j DROP

# --- ICMP ---
# TODO
iptables -A INPUT -p icmp --icmp-type echo-request \
    -m limit --limit 10/second --limit-burst 20 -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-reply   -j ACCEPT
# Allow ICMP "fragmentation needed" — critical for PMTUD (lesson from incident NET-4521)
iptables -A INPUT -p icmp --icmp-type fragmentation-needed -j ACCEPT


# --- Logging for dropped packets (optional but recommended) ---
# TODO
iptables -A INPUT   -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "[IPT DROP INPUT] " --log-level 4
iptables -A FORWARD -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "[IPT DROP FORWARD] " --log-level 4

echo "Firewall rules applied successfully"
