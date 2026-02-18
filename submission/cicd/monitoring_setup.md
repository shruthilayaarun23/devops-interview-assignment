# Monitoring and Observability Setup

## Metrics

<!-- What metrics would you collect? Consider:
- Application-level metrics (request latency, error rate, throughput)
- Infrastructure metrics (CPU, memory, disk, network)
- Business metrics (video chunks processed, upload success rate)
- Edge device metrics
-->
- Application: request latency (p50/p95/p99), error rates, Kafka consumer lag (the main signal for pipeline health), chunk processing throughput, and S3 upload success rate.
- Infrastructure: CPU/memory per pod and node, GPU utilisation and temperature on inference nodes, disk usage on edge devices (root and video buffer separately), and VPN upload throughput vs. the 50 Mbps site limit.
- Business: video data freshness (time from camera event to queryable in cloud), active camera streams per site vs. expected, and edge device/VPN uptime per site.
- Edge metrics are scraped by a Prometheus instance on the device and pushed to cloud via remote_write over the VPN. If the VPN drops, metrics buffer locally and flush on reconnect, so we don't lose visibility exactly when we need it most.
## SLOs (Service Level Objectives)

<!-- Define SLOs for the video analytics platform. Consider:
- Availability target
- Latency targets
- Data freshness (how stale can video data be?)
- Edge device uptime
-->
| SLO                        | Target         | Window         |
| Inference API availability | 99.9%          | 30-day rolling |
| Inference API p99 latency  | < 500ms        | 1-hour rolling |
| Video data freshness       | < 5 minutes    | 1-hour rolling |
| Edge device uptime         | 99.5% per site | Monthly        |
| VPN uptime                 | 99.5% per site | Monthly        |
| S3 upload success rate     | 99.9%          | 30-day rolling |

If any service burns through more than 50% of its monthly error budget in a single week, deployments to that service are paused until the budget recovers.
## Alerting

<!-- Define alerting rules and thresholds. Consider:
- What triggers a page vs. a ticket?
- Alert fatigue prevention
- Escalation path
-->
- Pages:
    - Inference API error rate > 5% for 5 minutes
    - Inference API p99 > 1s for 10 minutes
    - Video freshness > 15 minutes
    - VPN down > 10 minutes at any site
    - Kafka lag growing continuously for > 15 minutes
    - GPU temperature > 85°C
    - Video buffer disk > 90%

- Tickets :
    - S3 upload success rate < 99.9% for 1 hour
    - Camera offline > 30 minutes
    - Edge device disk > 80%
    - Kafka lag elevated but stable
    - Edge device failing healthcheck > 5 minutes
    - Error budget > 50% consumed in a week

- Keeping alert noise down: every alert requires a sustained duration before firing. Camera alerts are grouped per site (one alert, not one per camera). Kafka lag only pages if it's growing — a stable elevated lag isn't an emergency.

## Escalation

<!-- Define the escalation process:
- L1: automated response
- L2: on-call engineer
- L3: senior/specialist
- When to involve customers
-->
- L1 - Automation (0-5 min): PagerDuty runbooks handle the common cases automatically - restarting crashed containers, flushing stale consumer groups, clearing full tmp directories. Nobody gets woken up if automation can fix it.
- L2 - On-call engineer (5-30 min): Takes over if automation doesn't resolve it. Has access to all dashboards, kubectl, and deploy.py rollback. Expected to triage and either fix or escalate.
- L3 - Senior/specialist (30 min+): For anything requiring deep knowledge of the Kafka Streams topology, inference pipeline, or VPN/network infrastructure. Also the escalation path if multiple sites are affected simultaneously.
Customer communication: Engineering tells the account team; the account team tells the customer. Customers are notified if freshness exceeds 15 minutes or cameras are fully offline for more than 30 minutes.
## Dashboards

<!-- What dashboards would you create? What's on each one? -->
- Platform Overview: overall system health, active sites, SLO burn rates, and open incidents. The first place anyone looks.
- Video Processing Pipeline: Kafka consumer lag, chunk throughput, S3 upload success rate, and end-to-end freshness. Includes a per-site lag heatmap to spot which sites are struggling.
- Inference API: request rate, error rate, latency per endpoint, GPU utilisation and memory per node.
- Edge Device Fleet: one row per site: VPN status, camera count, disk usage, last healthcheck result, upload throughput. Colour-coded so fleet-wide problems are obvious at a glance.
- Cost and Capacity: monthly spend by service, node utilisation trends, and Kafka lag history for right-sizing decisions. Updated daily.