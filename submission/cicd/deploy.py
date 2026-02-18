#!/usr/bin/env python3
"""
deploy.py — Deployment automation script

TASK: Implement a deployment script for the video-analytics service.

Requirements:
  - argparse CLI with subcommands: deploy, rollback, status
  - deploy: takes --environment (staging/production), --image-tag, --dry-run
  - rollback: takes --environment, --revision (optional, defaults to previous)
  - status: takes --environment, shows current deployment state
  - Health check function that verifies deployment success
  - Rollback function that reverts to previous version on failure
  - Logging throughout

You don't need actual kubectl/AWS calls — implement the logic with
print statements or subprocess calls that would work in a real environment.
"""

import argparse
import logging
import subprocess
import sys
import time
from datetime import datetime

ENVIRONMENTS = ["staging", "production"]
NAMESPACE = "video-analytics"
DEPLOYMENT_NAME = "video-processor"
ECR_REGISTRY = "123456789012.dkr.ecr.us-east-1.amazonaws.com"
IMAGE_NAME = f"{ECR_REGISTRY}/video-processor"
HEALTH_CHECK_INTERVAL = 10  # seconds between health check polls

def setup_logging():
    """Configure structured logging to stdout."""
    logging.basicConfig(
        level=logging.INFO,
        format="[%(asctime)s] %(levelname)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%SZ",
        stream=sys.stdout,
    )

log = logging.getLogger(__name__)

# ============================================
# HELPERS
# ============================================

def run(cmd, dry_run=False, check=True):
    """
    Run a shell command, log it, and return the output.
    If dry_run=True, log the command but don't execute it.
    """
    log.info(f"{'[DRY RUN] ' if dry_run else ''}$ {' '.join(cmd)}")
    if dry_run:
        return "[dry-run: no output]"
    result = subprocess.run(cmd, capture_output=True, text=True, check=check)
    if result.stdout.strip():
        log.debug(result.stdout.strip())
    return result.stdout.strip()


def kubectl(*args, dry_run=False, check=True):
    """Wrapper around kubectl for the video-analytics namespace."""
    return run(["kubectl", "-n", NAMESPACE, *args], dry_run=dry_run, check=check)


def confirm(prompt):
    """Prompt for confirmation in interactive mode."""
    answer = input(f"{prompt} [y/N]: ").strip().lower()
    if answer != "y":
        log.info("Aborted by user")
        sys.exit(0)


def parse_args():
    """Parse command line arguments with subcommands."""
    # TODO: Implement argparse with deploy, rollback, status subcommands
    parser = argparse.ArgumentParser(
        description="Deployment automation for video-analytics",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python deploy.py deploy --environment staging --image-tag v1.4.2
  python deploy.py deploy --environment production --image-tag v1.4.2 --dry-run
  python deploy.py rollback --environment staging
  python deploy.py rollback --environment production --revision 3
  python deploy.py status --environment production
        """,
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    # --- deploy ---
    deploy_parser = subparsers.add_parser("deploy", help="Deploy a new image tag")
    deploy_parser.add_argument(
        "--environment",
        required=True,
        choices=ENVIRONMENTS,
        help="Target environment",
    )
    deploy_parser.add_argument(
        "--image-tag",
        required=True,
        help="Image tag to deploy (e.g. v1.4.2)",
    )
    deploy_parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print commands without executing them",
    )
    deploy_parser.add_argument(
        "--timeout",
        type=int,
        default=300,
        help="Health check timeout in seconds (default: 300)",
    )

    # --- rollback ---
    rollback_parser = subparsers.add_parser("rollback", help="Rollback to a previous revision")
    rollback_parser.add_argument(
        "--environment",
        required=True,
        choices=ENVIRONMENTS,
        help="Target environment",
    )
    rollback_parser.add_argument(
        "--revision",
        type=int,
        default=None,
        help="Revision number to roll back to (default: previous revision)",
    )

    # --- status ---
    status_parser = subparsers.add_parser("status", help="Show current deployment state")
    status_parser.add_argument(
        "--environment",
        required=True,
        choices=ENVIRONMENTS,
        help="Target environment",
    )

    return parser.parse_args()

def health_check(environment, timeout=300):
    """
    Poll rollout status until all replicas are ready or timeout is reached.
    Returns True if healthy, False if timed out or failed.
    """
    log.info(f"Running health check for {DEPLOYMENT_NAME} in {environment} (timeout: {timeout}s)")
    deadline = time.time() + timeout
    attempt = 0

    while time.time() < deadline:
        attempt += 1
        try:
            # Check rollout status
            rollout_status = kubectl(
                "rollout", "status", f"deployment/{DEPLOYMENT_NAME}",
                "--timeout=10s",
                check=False,
            )

            # Check that all pods are ready
            ready = kubectl(
                "get", "deployment", DEPLOYMENT_NAME,
                "-o", "jsonpath={.status.readyReplicas}/{.status.replicas}",
                check=False,
            )

            log.info(f"[attempt {attempt}] Ready replicas: {ready} — {rollout_status}")

            if "successfully rolled out" in rollout_status:
                log.info(f"Health check passed — deployment is healthy")
                return True

        except Exception as e:
            log.warning(f"Health check attempt {attempt} error: {e}")

        time.sleep(HEALTH_CHECK_INTERVAL)

    log.error(f"Health check timed out after {timeout}s")
    return False


def deploy(environment, image_tag, dry_run=False):
    """Deploy the application to the specified environment."""
    # TODO: Implement deployment logic
    image = f"{IMAGE_NAME}:{image_tag}"

    log.info(f"{'[DRY RUN] ' if dry_run else ''}Deploying {image} to {environment}")

    # Safety gate for production
    if environment == "production" and not dry_run:
        confirm(f"You are deploying {image} to PRODUCTION. Are you sure?")

    # Record current revision before deploying (used for auto-rollback)
    current_revision = None
    if not dry_run:
        try:
            current_revision = kubectl(
                "rollout", "history", f"deployment/{DEPLOYMENT_NAME}",
                "--output=jsonpath={.metadata.annotations.deployment\\.kubernetes\\.io/revision}",
                check=False,
            )
            log.info(f"Current revision: {current_revision}")
        except Exception:
            log.warning("Could not retrieve current revision — auto-rollback may not be available")

    # Update the image
    kubectl(
        "set", "image",
        f"deployment/{DEPLOYMENT_NAME}",
        f"{DEPLOYMENT_NAME}={image}",
        dry_run=dry_run,
    )

    # Annotate with deploy metadata
    timestamp = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    kubectl(
        "annotate", "deployment", DEPLOYMENT_NAME,
        f"deployment.vlt.io/deployed-at={timestamp}",
        f"deployment.vlt.io/image-tag={image_tag}",
        f"deployment.vlt.io/environment={environment}",
        "--overwrite",
        dry_run=dry_run,
    )

    if dry_run:
        log.info("[DRY RUN] Skipping health check")
        return

    # Health check — auto-rollback on failure
    if not health_check(environment, timeout=timeout):
        log.error("Deployment failed health check — initiating automatic rollback")
        rollback(environment, revision=int(current_revision) if current_revision else None)
        sys.exit(1)

    log.info(f"Deployment of {image_tag} to {environment} completed successfully")


def rollback(environment, revision=None):
    """Rollback to a previous deployment revision."""
    # TODO: Implement rollback logic
    if revision:
        log.info(f"Rolling back {DEPLOYMENT_NAME} in {environment} to revision {revision}")
        kubectl(
            "rollout", "undo",
            f"deployment/{DEPLOYMENT_NAME}",
            f"--to-revision={revision}",
        )
    else:
        log.info(f"Rolling back {DEPLOYMENT_NAME} in {environment} to previous revision")
        kubectl(
            "rollout", "undo",
            f"deployment/{DEPLOYMENT_NAME}",
        )

    log.info("Waiting for rollback to complete...")
    if not health_check(environment, timeout=180):
        log.error("Rollback did not complete successfully — manual intervention required")
        sys.exit(2)

    log.info(f"Rollback in {environment} completed successfully")


def status(environment):
    """Show current deployment status."""
    # TODO: Implement status check
    log.info(f"Deployment status for {environment}")
    print()

    # Deployment overview
    kubectl("get", "deployment", DEPLOYMENT_NAME, "-o", "wide")
    print()

    # Pod state
    kubectl("get", "pods", "-l", f"app={DEPLOYMENT_NAME}", "-o", "wide")
    print()

    # Rollout history
    kubectl("rollout", "history", f"deployment/{DEPLOYMENT_NAME}")
    print()

    # Recent events
    kubectl(
        "get", "events",
        "--field-selector", f"involvedObject.name={DEPLOYMENT_NAME}",
        "--sort-by=.lastTimestamp",
    )


def main():
    # TODO: Wire up argument parsing to functions
    setup_logging()
    args = parse_args()

    if args.command == "deploy":
        deploy(
            environment=args.environment,
            image_tag=args.image_tag,
            dry_run=args.dry_run,
            timeout=args.timeout,
        )
    elif args.command == "rollback":
        rollback(
            environment=args.environment,
            revision=args.revision,
        )
    elif args.command == "status":
        status(environment=args.environment)


if __name__ == "__main__":
    main()
