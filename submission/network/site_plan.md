# Site Network Plan

Review `data/site_spec.json` for the customer site specification.

## VLAN Design

<!-- Define VLANs for the site. Consider:
- Camera VLAN (isolated from other traffic)
- Management VLAN
- Edge device placement
- Existing VLANs from site_spec.json
-->


| VLAN ID | Name | Subnet | Purpose |
|---------|------|--------|---------|
| 1 | management | 10.50.1.0/24 | IT management, SSH access, edge device eno1 |
| 10 | corporate | 10.50.10.0/24 | Office workstations (existing, unchanged) |
| 20 | cameras | 10.50.20.0/24 | IP cameras only - isolated, no route to other VLANs |
VLAN 1 and VLAN 10 are pre-existing per site_spec.json. VLAN 20 is new for this deployment.


## IP Addressing Scheme

<!-- Define static IP assignments for key devices and DHCP ranges for cameras -->
**VLAN 1 - Management (10.50.1.0/24)**

| Address | Device | Notes |
|---------|--------|-------|
| 10.50.1.1 | Site gateway | Existing |
| 10.50.1.10 | DNS server / NTP server | Existing |
| 10.50.1.11 | DNS server (secondary) | Existing |
| 10.50.1.50 | Edge device eno1 | Static - management + WAN uplink |
| 10.50.1.51-100 | Reserved | Future edge devices or infrastructure |
| 10.50.1.200-254 | DHCP pool | Management workstations and IT equipment |

**VLAN 20 - Camera (10.50.20.0/24)**

| Address | Device | Notes |
|---------|--------|-------|
| 10.50.20.1 | VLAN 20 gateway | On managed switch - routes to eno2 only |
| 10.50.20.101 | CAM-001 (Axis P3265-LVE) | Loading Dock A - static |
| 10.50.20.102 | CAM-002 (Axis P3265-LVE) | Loading Dock B - static |
| 10.50.20.103 | CAM-003 (Axis Q6135-LE) | Parking Lot North - static |
| 10.50.20.104 | CAM-004 (Axis P3265-LVE) | Warehouse Entrance - static |
| 10.50.20.105 | CAM-005 (Axis Q6135-LE) | Parking Lot South - static |
| 10.50.20.106 | CAM-006 (Axis P3265-LVE) | Receiving Area - static |
| 10.50.20.107 | CAM-007 (Axis P3265-LVE) | Shipping Area - static |
| 10.50.20.108 | CAM-008 (Axis P3265-LVE) | Main Hallway - static |
| 10.50.20.200 | Edge device eno2 | Static - camera VLAN gateway |
| 10.50.20.201-254 | DHCP pool | Reserved for future cameras |

Cameras are assigned static IPs despite the site_spec.json listing DHCP. Static assignment ensures `healthcheck.sh` and `firewall_rules.sh` can reliably target known addresses, and prevents a DHCP lease expiry from breaking RTSP streams.


## Camera Network Isolation

<!-- How will you isolate camera traffic from management and corporate networks? -->
Camera traffic is isolated at three layers:

**Layer 1 - Physical/VLAN** - cameras are connected to switch ports configured as access ports on VLAN 20 only. They have no physical path to VLAN 1 or VLAN 10 at the switch level. The managed switch has no inter-VLAN routing configured between VLAN 20 and any other VLAN.

**Layer 2 - Routing** - the only device with a leg in VLAN 20 is the edge device (eno2). There is no default gateway on VLAN 20 that routes to the corporate or management networks. Cameras can only reach the edge device.

**Layer 3 - Firewall** - `firewall_rules.sh` enforces this in iptables: the FORWARD chain drops all traffic from eno2 destined for the management VLAN, corporate VLAN, or any other RFC1918 space. Even if a camera were compromised, it could not reach management infrastructure.


## Edge Device Network Configuration

<!-- Describe the network setup for the edge device (which NIC connects to which VLAN, IP assignments, routing) -->
The Dell PowerEdge XR4000 has two NICs:

**eno1 — Management + WAN**
- IP: 10.50.1.50/24 (static)
- Default gateway: 10.50.1.1
- MTU: 1500 (matches site gateway — see incident NET-4521)
- Carries: SSH management access, VPN tunnel to AWS, S3 uploads, SQS events, CloudWatch metrics

**eno2 — Camera VLAN**
- IP: 10.50.20.200/24 (static)
- No default gateway — isolated to VLAN 20 only
- MTU: 1500 (jumbo frames explicitly not applied here pending validation — see NET-4521)
- Carries: RTSP streams from all 8 cameras, ONVIF discovery traffic

DNS: 10.50.1.10, 10.50.1.11 (management VLAN DNS servers)
NTP: 10.50.1.10 (management VLAN NTP server)

## Traffic Flow

<!-- Describe how video data flows from cameras through the edge device to the cloud -->
```
Cameras (VLAN 20)
  │  RTSP/ONVIF over eno2
  ▼
Edge Device
  │  Video ingest container fragments streams into MPEG-TS chunks
  │  AI inference runs locally on NVIDIA T4
  │  Chunks written to local buffer (/var/video-buffer)
  │
  │  S3 upload over eno1 → IPSec VPN → AWS VPC
  ▼
Amazon S3 (vlt-video-chunks-prod)
  │
  ▼
Video Processor (Kafka Streams on EKS) — concatenates chunks, writes final segments
  │
  ▼
Amazon S3 (processed video) + RDS (metadata) + SQS (inference events)
  │
  ▼
API Gateway → Customer dashboard
```

All cloud-bound traffic (S3, SQS, CloudWatch, ECR) traverses the IPSec VPN over eno1. Camera traffic never leaves the edge device, it is ingested on eno2 and processed locally. The VPN upload is bandwidth-limited to 50 Mbps in the video-ingest container configuration, leaving headroom on the 100 Mbps WAN link for management traffic.