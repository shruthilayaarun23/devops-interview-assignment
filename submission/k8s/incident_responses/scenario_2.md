# Incident Response: Scenario 2

Review the data in `data/incident/scenario_2/` and answer the following.

## What is happening?

<!-- Describe the symptoms and current state of the service -->
The inference-api pods are running and healthy but receiving no traffic. All connection attempts time out and the service endpoints list is empty despite 3 pods being up for 2 hours.

## Root Cause

<!-- Identify the root cause(s) of the issue. There may be more than one. Reference specific evidence from the manifests and debug output -->
Two separate issues, both blocking traffic independently:
1. Service selector mismatch - the Service requires app=inference-api AND tier=backend, but the pod template only has app=inference-api. Kubernetes can't match any pods, so endpoints stays empty and all traffic times out.
2. NetworkPolicy blocks the caller - the NetworkPolicy only permits ingress from app=api-gateway. The pod making the request (web-frontend) doesn't have that label, so even if the selector were fixed it would still be blocked at the network level.

## Immediate Remediation

<!-- What commands or changes would you make RIGHT NOW to restore service? -->
Add tier: backend to the deployment's pod template labels. This will immediately populate the service endpoints and restore traffic from permitted callers. The frontend timeout will persist until the network policy is resolved, but based on the architecture the correct fix is to route that call through the API Gateway rather than adding the frontend to the allowlist.

## Long-term Fix

<!-- What changes should be made to prevent this from recurring? -->
Based on the architecture, the API Gateway is the intended entry point to backend services. The frontend calling inference-api directly suggests a missing or misconfigured route in the gateway. That call path should be moved behind the gateway, which also means the NetworkPolicy is actually correct as written, web-frontend shouldn't be in the allowlist.

## Prevention

<!-- What monitoring, alerts, or processes would catch this earlier? -->
- Run kubectl get endpoints as the first step whenever a service is unreachable — empty endpoints immediately narrows the problem to a selector mismatch
- Lint manifests in CI to catch mismatches between Service selectors and pod template labels before they reach the cluster
- Alert on any production service with zero endpoints for more than 60 seconds