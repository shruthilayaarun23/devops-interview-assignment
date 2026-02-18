# Incident Response: Scenario 3

Review the data in `data/incident/scenario_3/` and answer the following.

## What is happening?

<!-- Describe the symptoms and current state of the deployment rollout -->
A rolling deployment of chunk-processor:v3.0.0-rc1 is stalled. The new pod has been in ImagePullBackOff for 15 minutes while the three old pods remain running. There is no live service impact but the rollout will not progress until the issue is resolved.

## Root Cause

<!-- Identify the root cause of the issue. Reference specific evidence from the rollout status and pod description -->
The ServiceAccount is missing its IAM role annotation. Without it, IRSA never injects AWS credentials into the pod, so the kubelet has no valid token to authenticate against ECR. The error message confirms this directly as the authorisation token has expired or was never issued. The intended annotation is:
eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/chunk-processor-ecr-role

## Immediate Remediation

<!-- What commands or changes would you make RIGHT NOW to restore service? -->
Add the missing annotation to the ServiceAccount. The pod will automatically receive credentials on its next restart and the rollout will resume. No rollback is needed as the old pods are healthy and serving traffic throughout.

## Long-term Fix

<!-- What changes should be made to prevent this from recurring? -->
The ServiceAccount and its IAM role annotation should be managed in Terraform alongside the rest of the service infrastructure, so it cannot be omitted during future deployments. The chunk-processor-ecr-role trust policy should also be codified and reviewed as part of any new service onboarding process.

## Prevention

<!-- What monitoring, alerts, or processes would catch this earlier? -->
- Verify the image exists in ECR and that the ServiceAccount has valid IAM credentials as part of the CI pipeline before a deployment is applied.
- Alert on ImagePullBackOff events in production.
- Include IAM annotation validation as a standard check in the manifest linting step alongside selector and label checks.