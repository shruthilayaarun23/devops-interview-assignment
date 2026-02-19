# Post-Incident Report

## Incident Summary
| Field             | Value                                                                                                                                     |
| Date              | 2025-11-12                                                                                                                                |
| Duration          | 45 minutes (08:15 - 09:00 UTC)                                                                                                            |
| Severity          | P1                                                                                                                                        |
| Services Affected | Video upload pipeline, VPN tunnel - SITE-2847 (Denver)                                                                                    |
| Customer Impact   | Video data for Acme Distribution was up to 45 minutes stale. No permanent data loss, chunks were queued locally and uploaded on recovery. |


## What Happened

<!-- Brief narrative of the incident -->

A scheduled network maintenance change (NET-4521) intended to enable jumbo frames on the camera VLAN interface (`eno2`) was accidentally applied to the WAN interface (`eno1`) instead. The site gateway doesn't support jumbo frames, so IPSec packets immediately began failing reassembly. VPN throughput collapsed from 50 Mbps to ~1.8 Mbps, S3 uploads failed completely, and the tunnel flapped four times as DPD keepalives timed out. Small-packet health checks continued passing throughout, masking the severity. The NOC reverted the MTU at 09:00, immediately restoring uploads and tunnel stability.

## Timeline

<!-- Detailed timeline with timestamps -->
| Time (UTC)    | Event                                                                |
| 07:30 - 08:10 | All systems normal, uploads running at 41-44 Mbps                    |
| 08:15         | NET-4521 applied - `eno1` MTU changed from 1500 to 9000              |
| 08:15         | strongSwan: keepalive packet size exceeds path MTU                   |
| 08:17         | First S3 upload timeout                                              |
| 08:18         | Gateway returning ICMP "fragmentation needed"                        |
| 08:20         | CloudWatch: upload errors spike to 18 per 5-min window               |
| 08:21         | First VPN tunnel flap                                                |
| 08:22         | Throughput measured at 1.8 Mbps - app logs flag possible MTU issue   |
| 08:25         | Second tunnel flap. Disk usage 85%, 22 chunks queued                 |
| 08:30         | CRITICAL alert fired. Disk at 85%                                    |
| 08:35         | Third tunnel flap, 34% ESP packet loss                               |
| 08:45         | NOC engineer begins investigation                                    |
| 08:50         | Fourth tunnel flap                                                   |
| 09:00         | MTU reverted to 1500. Uploads resume immediately, tunnel stabilises  |

---
## Root Cause

<!-- Technical root cause -->
NET-4521 was a valid change, enabling jumbo frames on `eno2` for camera VLAN performance. The netplan config was incorrectly written to target `eno1` instead. Because the site gateway has a hard MTU of 1500 and cannot handle jumbo frames, IPSec ESP packets were immediately dropped or fragmented beyond recovery. Path MTU Discovery failed because the DF bit was set, producing sustained fragmentation failures rather than a graceful fallback.

## Resolution

<!-- How was the incident resolved? -->

The NOC engineer reverted `eno1` MTU to 1500 via `ip link set` and corrected the netplan config to persist the change across reboots. Uploads resumed within seconds of the revert. The intended change (jumbo frames on `eno2`) was not re-applied pending a reviewed netplan config.

## Impact

<!-- Quantify the impact: data loss, downtime, customer-facing effects -->

- **Upload downtime:** 45 minutes
- **Chunks lost:** 0 — all queued locally and flushed on recovery
- **Peak disk usage:** 91% (recovered to 65% within 15 minutes of resolution)
- **VPN tunnel flaps:** 4
- **Data freshness impact:** up to 45 minutes of stale video for Acme Distribution
- **Customer notification:** account team notified at 08:35


## Action Items

<!-- Specific, assignable action items to prevent recurrence -->

| Action                                                                                 | Owner         | Priority | Due Date   |
| Add MTU validation for `eno1` to `healthcheck.sh`                                      | Edge Platform | High     | 2025-11-19 |
| Split netplan config into per-interface files (`10-management.yaml`, `20-camera.yaml`) | Edge Platform | High     | 2025-11-19 |
| Add pre-apply connectivity test to all network change scripts                          | Edge Platform | High     | 2025-11-26 |
| Alert on VPN throughput drop below 10 Mbps for >2 minutes                              | Monitoring    | High     | 2025-11-19 |
| Alert on 3+ tunnel flaps within 30 minutes                                             | Monitoring    | Medium   | 2025-11-26 |
| Link active change tickets to alerts on affected devices                               | Monitoring    | Medium   | 2025-11-26 |
| Configure MSS clamping on VPN tunnel (resilience measure)                              | Network       | Medium   | 2025-11-26 |
| Define expected MTU per interface in config management                                 | Edge Platform | Medium   | 2025-12-03 |
| Review and update CRITICAL alert response SLA (target: 5 min)                          | NOC           | Low      | 2025-11-26 |


## Lessons Learned

<!-- What went well, what could be improved -->
### What went well

- The application identified the likely root cause in its own logs at 08:22 - "large packets timing out, small health checks succeed"
- Local buffering on the edge device meant no video data was permanently lost
- Once the root cause was identified, the fix took under a minute and worked immediately

### What could be improved

- The wrong interface was targeted because there was no diff review or pre-apply validation on the netplan change
- Health checks passed throughout, giving a false signal that the device was healthy
- 15 minutes passed between the CRITICAL alert and the start of investigation
- No alert existed for VPN throughput degradation or repeated tunnel flaps - only for tunnel up/down state
-
