# Incident Response: Scenario 1

Review the data in `data/incident/scenario_1/` and answer the following.

## What is happening?

<!-- Describe the symptoms and current state of the pod -->
The pods are repeatedly OOMKilled and stuck in CrashLoopBackOff. They've restarted 7 times and aren't recovering.

## Root Cause

<!-- Identify the root cause of the issue. Reference specific evidence from the pod description, events, and logs -->
The JVM heap is set to 384MB but the container limit is only 512MB. That leaves just 128MB for everything else the JVM needs such as threads, metaspace, buffers. It's not enough, and the kernel kills the process when it goes over.

## Immediate Remediation

<!-- What commands or changes would you make RIGHT NOW to restore service? -->
Raise the memory limit and align the JVM heap to match.

## Long-term Fix

<!-- What changes should be made to prevent this from recurring? -->
The code is allocating a new buffer per fragment in memory. It should stream directly to S3 via multipart upload instead, so there's no large in-memory accumulation.

## Prevention

<!-- What monitoring, alerts, or processes would catch this earlier? -->
- Always leave headroom above the JVM heap for off-heap memory, 2:1 limit-to-request is a safe rule of thumb
- Use -XX:MaxRAMPercentage=75.0 so the heap size automatically tracks the container limit
- Alert on memory usage at 80% - the logs were showing warnings before the crash, which was enough time to catch it earlier