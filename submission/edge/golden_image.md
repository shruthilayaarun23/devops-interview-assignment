# Golden Image Strategy

## Overview

<!-- Describe your approach to creating and maintaining a golden image for edge devices -->
The golden image is a versioned, pre-baked OS image for the Dell PowerEdge XR4000 edge devices. It contains everything needed to run the video analytics stack except site-specific configuration, which is injected at first boot. A new image is built and tested before each planned rollout, and every deployed device runs a known, auditable image version. This eliminates configuration drift across the 50+ site fleet and makes rollback a predictable operation rather than a manual recovery process.

## Base Image

<!-- What goes into the base image vs. site-specific configuration? -->
What goes into the golden image:

- Ubuntu 22.04 LTS (minimal server install)
- NVIDIA driver (pinned version, e.g. 535)
- NVIDIA Container Toolkit
- Docker CE (pinned version)
- video-ingest systemd service unit file
- healthcheck.sh and setup.sh scripts
- UFW rules and SSH hardening config
- fail2ban, chrony, logrotate configuration
- CloudWatch/Prometheus node exporter
- AWS CLI (for ECR auth and S3 operations)

What does NOT go into the golden image:

- Site ID, VPN credentials, or camera IPs
- NTP server address (varies per site network)
- Application container images (pulled from ECR at first boot)
- TLS certificates or IAM credentials
- Customer-specific environment variables

The principle is: the image should be able to ship to any site. Everything that makes it specific to SITE-2847 is injected separately.

## Image Creation Process

<!-- Step-by-step process for building the golden image -->
- Start from Ubuntu 22.04 LTS minimal ISO - no desktop, no extras
- Run setup.sh in non-interactive mode against a clean VM or bare metal reference host, with SITE_ID=golden to suppress site-specific steps
- Verify - run healthcheck.sh and confirm all checks pass except site-specific ones (VPN, cameras)
- Sysprep - clear SSH host keys, machine ID, cloud-init state, and any logs generated during build:
- Snapshot: create the image using the tool appropriate to the deployment target 
- Tag with a version and build date: edge-golden-v1.4.2-20251115
- Store in S3 (s3://vlt-edge-images/) and update the image manifest
- Sign the image checksum with a GPG key - devices verify the signature before flashing

## Configuration Management

<!-- How do you handle per-site configuration on top of the golden image? -->
Site-specific configuration is delivered via a cloud-init user-data file, generated per site from the site spec JSON at deployment time. On first boot, cloud-init:

- Sets the SITE_ID environment variable and writes it to /etc/environment
- Writes the VPN configuration (pre-shared key or certificate) from Secrets Manager
- Configures chrony with the site NTP server
- Writes the camera IP list for healthcheck
- Triggers a one-time systemctl start video-ingest after cloud-init completes

This keeps the golden image identical across all sites while allowing full per-site customisation without manual SSH access. For subsequent configuration changes (not image updates), Ansible or SSM Run Command can push updated config files to running devices.

## Patching and Updates

<!-- How do you handle OS and application updates across deployed edge devices? -->
OS and driver patches are handled by rebuilding the golden image on a monthly cadence and rolling it out as a staged update:

- Build and test the new image in a lab device
- Deploy to 1-2 canary sites and monitor with healthcheck.sh for 48 hours
- If healthy, roll out to 10% of the fleet, then 50%, then 100%, with a 24-hour pause between each wave
- Devices pull the new image during a scheduled maintenance window (02:00 - 04:00 local time) to avoid disrupting customer operations

Application container updates (video-ingest) are independent of the image and follow the same canary pattern via ECR image tags. The systemd service pulls the :stable tag on restart, so promoting a new version is a matter of moving the tag in ECR and restarting the service so no re-imaging required.

## Rollback

<!-- How do you handle rolling back a bad image update? -->
Each device records its current and previous image version in /etc/edge-image-version. Rollback is a two-step operation:

- Identify bad devices - the central monitoring dashboard flags devices where healthcheck.sh returns critical after an update wave
- Re-flash previous image - the previous golden image is always retained in S3. A rollback job (triggered via SSM or manually) flashes the previous image and restores the site-specific cloud-init config on top

For application container rollbacks (without re-imaging), the :stable ECR tag is moved back to the previous image digest and the service is restarted across affected devices - this completes in under 2 minutes per device.
The staging cadence means a bad update is caught before it reaches the full fleet, limiting blast radius to a small number of sites at any given time.