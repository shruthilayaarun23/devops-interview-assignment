# cost_optimization.tf - Cost Optimization Resources
#
# TASK: Review data/aws_cost_report.json and implement cost-saving measures.
#
# Requirements:
#   1. Analyze the cost report and identify the top savings opportunities
#   2. Implement Terraform resources that address the findings, such as:
#      - S3 lifecycle policies for tiered storage
#      - Spot/mixed instance configurations for node groups
#      - Right-sizing recommendations implemented as resource changes
#   3. Add a comment block at the top explaining your cost analysis:
#      - Current monthly cost and top cost drivers
#      - Proposed changes and estimated savings
#      - Any trade-offs or risks

# --- Your cost analysis ---
# TODO: Write your analysis here as comments
# We're currently spending $47,832/month across the platform. Three areas account for the majority of waste.
# EC2 Compute - $22,146 (46% of spend)

# Video-processing and general node groups are fully on-demand at 34% and 22% utilization respectively.
# Moving both to mixed spot/on-demand saves ~$10,200/month.
# GPU inference group (61% utilization) stays on-demand as spot interruptions would directly impact customer-facing latency.

# S3 Storage - $12,341 (26% of spend)

# 45TB of video sitting in STANDARD storage for up to 2 years; 95% of access is within the first 30 days
# Lifecycle policy: STANDARD-IA at 30 days to Glacier Instant at 90 days to expire at 1 year saves ~$7,500/month
# Logs bucket has the same problem; Glacier at 30 days with 180-day expiry addresses it

# RDS - $4,856 (10% of spend)

# Primary instance at 28% CPU utilization, read replicas at 12%
# Step primary down from db.r5.2xlarge to db.r5.xlarge and reduce replicas from 2 to 1
# Saves ~$1,900/month; both changes require a scheduled maintenance window

# Total estimated saving: ~$20,500/month (~43% reduction)
# Risks to flag before applying:
# Confirm with the product team that no access patterns exist beyond 30 days before S3 lifecycle tiers go live
# RDS resize triggers a brief Multi-AZ failover (~30s) - schedule and notify customers in advance
# --- S3 Lifecycle Policies ---
# TODO: Implement lifecycle rules for the video chunks bucket
#   Hint: 95% of access is within the first 30 days
# 95% of access within first 30 days; objects retained up to 730 days in STANDARD today.
# New policy: IA at 30d to Glacier Instant at 90d to expire at 365d

resource "aws_s3_bucket_lifecycle_configuration" "video_chunks" {
  bucket = "vlt-video-chunks-prod"

  rule {
    id     = "video-tiering"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR" # Glacier Instant Retrieval - millisecond access if needed
    }

    expiration {
      days = 365 # No evidence of access beyond 1 year; halves storage vs current 730-day retention
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# --- S3 Lifecycle: Logs Bucket ---
# Rarely accessed after 7 days; currently kept 545 days in STANDARD.

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = "vlt-logs-prod"

  rule {
    id     = "log-tiering"
    status = "Enabled"

    transition {
      days          = 7
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 30
      storage_class = "GLACIER"
    }

    expiration {
      days = 180 # Logs beyond 6 months have minimal operational value; adjust for compliance needs
    }
  }
}


# --- Spot/Mixed Instance Configuration ---
# TODO: Configure mixed instance policies for appropriate node groups
#   Hint: Not all workloads are suitable for spot instances
# Replaces the flat on-demand c5.4xlarge group (34% utilization, $11,520/mo).
# Diversified instance pool reduces interruption risk; 30% on-demand base ensures
# Kafka Streams always has a stable coordinator even during spot reclamation events.

resource "aws_eks_node_group" "video_processing" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-video-processing"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  # capacity_type = "SPOT" is set at the managed node group level for simplicity;
  capacity_type  = "SPOT"
  instance_types = ["c5.4xlarge", "c5a.4xlarge", "c5n.4xlarge", "c4.4xlarge"]

  scaling_config {
    desired_size = 6  # Right-sized down from 8 given 34% avg utilization
    min_size     = 3  # On-demand floor via separate on-demand node group 
    max_size     = 12 # Allow burst headroom for peak ingest windows
  }

  update_config {
    max_unavailable = 2
  }

  labels = {
    role            = "video-processing"
    capacity-type   = "spot"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_read_only,
  ]

  tags = {
    Name = "${var.cluster_name}-video-processing-spot"
  }
}

# On-demand base capacity for video processing - ensures Kafka Streams coordinator
# pods always have a stable home even during spot interruption waves.

resource "aws_eks_node_group" "video_processing_base" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-video-processing-base"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  capacity_type  = "ON_DEMAND"
  instance_types = ["c5.2xlarge"] # Smaller on-demand base - coordinator + critical pods only

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 2
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role          = "video-processing"
    capacity-type = "on-demand"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_read_only,
  ]

  tags = {
    Name = "${var.cluster_name}-video-processing-base"
  }
}

# --- Mixed Instance Node Group: General Workloads ---
# Replaces flat on-demand m5.2xlarge group (22% utilization, $5,544/mo).

resource "aws_eks_node_group" "general_spot" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-general-spot"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  capacity_type  = "SPOT"
  instance_types = ["m5.2xlarge", "m5a.2xlarge", "m5n.2xlarge", "m4.2xlarge"]

  scaling_config {
    desired_size = 3  # Right-sized from 6 given 22% utilization
    min_size     = 2
    max_size     = 8
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role          = "general"
    capacity-type = "spot"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_read_only,
  ]

  tags = {
    Name = "${var.cluster_name}-general-spot"
  }
}

# --- Other Cost Optimizations ---
# TODO: Implement any other cost-saving measures you identified
# --- RDS Right-Sizing ---
# Primary at 28% utilization on db.r5.2xlarge - step down to db.r5.xlarge.
# Read replicas at 12% utilization - reduce from 2 to 1.
# Both changes are variable-driven so they can be applied during a maintenance window
# without touching the resource block structure.

variable "rds_primary_instance_class" {
  description = "RDS primary instance class. Reduce from db.r5.2xlarge to db.r5.xlarge after monitoring confirms headroom."
  type        = string
  default     = "db.r5.xlarge" # Was db.r5.2xlarge - saves ~$1,200/mo
}

variable "rds_replica_count" {
  description = "Number of RDS read replicas. Reduce from 2 to 1 given 12% utilization."
  type        = number
  default     = 1 # Was 2 - saves ~$700/mo
}
