# Root Cause Analysis

Review all files in `data/debug_scenario/` to investigate the incident.

## Summary

<!-- One-paragraph summary of what happened -->
At 08:15 UTC on 12 November 2025, a scheduled network maintenance change (NET-4521) incorrectly applied jumbo frame MTU (9000 bytes) to eno1, the management and WAN interface, instead of the intended eno2 (camera VLAN). Because the site gateway does not support jumbo frames, IPSec ESP packets immediately began fragmenting and failing reassembly, degrading VPN throughput from 50 Mbps to ~1.8 Mbps. S3 uploads failed completely while small health check packets continued passing, masking the severity. The VPN tunnel flapped four times between 08:21 and 08:51 as DPD keepalives timed out. Disk usage climbed from 52% to 91% as chunks queued locally. The NOC engineer reverted the MTU at 09:00, immediately restoring uploads and tunnel stability. Total incident duration: 45 minutes.
## Timeline

<!-- Reconstruct the incident timeline from the available data. Include timestamps. -->
| Time (UTC)   | Event                                                                                  |
|--------------|----------------------------------------------------------------------------------------|
| 07:30-08:10  | All systems normal. Upload success rate 100%, avg throughput 41-44 Mbps                |
| 08:15        | NET-4521 applied - `eno1` MTU changed from 1500 to 9000 via netplan                    |
| 08:15        | strongSwan logs: IKE SA keepalive packet size 9000 exceeds path MTU 1500               |
| 08:17        | First S3 upload timeout - `chunk-20251112-081200-cam001.ts` part 1/5                   |
| 08:18        | ICMP "fragmentation needed" messages from gateway 10.50.1.1 begin                      |
| 08:18        | VPN throughput degraded: 50 Mbps to 2.3 Mbps                                           |
| 08:18        | App logs: UFW blocks UDP traffic from camera VLAN on `eno1` (separate issue)           |
| 08:20        | CloudWatch: upload errors spike from 0 to 18 per 5-min window                          |
| 08:21        | First VPN tunnel flap - DPD timeout, tunnel down then re-established in 10s            |
| 08:21        | Uploads retry after tunnel recovery - still failing due to MTU                         |
| 08:22        | Throughput measured at 1.8 Mbps. App logs note possible MTU/fragmentation issue        |
| 08:25        | Second VPN tunnel flap. Disk usage 85%, 22 chunks queued                               |
| 08:30        | CRITICAL alert fired: EDGE_UPLOAD_FAILURE for SITE-2847                                |
| 08:35        | Third VPN tunnel flap. Sustained ESP packet loss: 34%                                  |
| 08:45        | NOC engineer begins investigation                                                      |
| 08:50        | Fourth VPN tunnel flap                                                                 |
| 09:00        | NOC reverts `eno1` MTU to 1500. Uploads resume immediately, tunnel stabilises          |
| 09:00        | CloudWatch: upload errors drop from 24 to 0. Disk usage begins recovering (91% to 65%) |

---


## Root Cause

<!-- What was the root cause? Be specific - reference log lines and metrics -->
The netplan configuration for NET-4521 was applied to `eno1` instead of `eno2`. This single misconfiguration caused the entire incident.

Specifically, at 08:15 the kernel logs show:
> `device eno1: MTU changed from 1500 to 9000 via netplan apply`

The site gateway (10.50.1.1) has a hard MTU of 1500 and does not support jumbo frames. IPSec ESP packets transmitted over the VPN are encapsulated with additional overhead, so an interface MTU of 9000 produced packets the gateway immediately rejected. strongSwan confirmed this at 08:15:
> `IKE SA keepalive: packet size 9000 exceeds path MTU 1500`

Path MTU Discovery (PMTUD) failed because the DF bit was set on ESP packets, and the ICMP "fragmentation needed" responses from the gateway were not being acted upon correctly. This produced sustained fragmentation failures rather than a graceful fallback. The tunnel throughput collapsed to ~1.8 Mbps and DPD keepalives began timing out, causing repeated tunnel flaps every ~10 minutes.


## Contributing Factors

<!-- What other factors contributed to the severity or duration of the incident? -->

- Health checks passed throughout: Docker container healthchecks and the VPN DPD mechanism use small packets that fit within the 1500-byte path MTU, so both continued reporting healthy. This delayed detection by masking the true severity of the degradation.

- 15-minute alert detection gap: the CRITICAL alert fired at 08:30 but the issue began at 08:15. The upload error alert threshold required a sustained failure window before paging, which is correct for avoiding false positives but meant 15 minutes of accumulating disk backlog before anyone was notified.

- 30-minute investigation delay: the alert fired at 08:30 but the NOC engineer didn't begin investigating until 08:45. This is a process gap, for a CRITICAL edge upload failure the response time should be faster.

- No change correlation in alerting: the monitoring system had no awareness of the NET-4521 change window. An alert that automatically flags active change tickets when an incident fires would have pointed to the root cause immediately.

## Evidence

<!-- Link specific log entries, metrics, and data points that support your analysis -->
| Evidence                                                                                           | Source  | Significance |
|----------------------------------------------------------------------------------------------------|---------|--------------|
| `eno1: MTU changed from 1500 to 9000 via netplan apply` at 08:15                                   | syslog  | Confirms exact time and cause of misconfiguration |
| `IKE SA keepalive: packet size 9000 exceeds path MTU 1500` at 08:15                                | VPN log | strong Swan immediately detected the MTU conflict |
| `fragmentation needed and DF set, mtu=1500` at 08:18                                               | syslog  | Gateway rejecting oversized packets |
| `Network throughput: 1.8 Mbps (expected 50 Mbps)` at 08:22                                         | App log | Quantifies impact of fragmentation on upload capacity |
| `Possible MTU/fragmentation issue: large packets timing out, small health checks succeed` at 08:22 | App log    | Application itself identified the likely cause |
| Upload errors: 0 → 18 → 24 → 0 between 08:15-09:00                                                 | CloudWatch | Correlates exactly with MTU change and revert |
| Four tunnel flaps at 08:21, 08:25, 08:35, 08:50                                                    | CloudWatch VPNTunnelStatus | Each flap triggered by DPD timeout caused by oversized keepalives |
| Disk usage: 52% → 91% between 08:15–08:45                                                          | CloudWatch EdgeDiskUsagePercent | 30 minutes of failed uploads accumulated ~40% disk in backlog |
| `eno1: MTU changed: 9000 -> 1500` + `ESP packet fragmentation stopped` at 09:00                    | VPN log | Revert immediately resolved fragmentation and stabilised tunnel |