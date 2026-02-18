variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string
}

variable "site_id" {
  description = "Customer site identifier"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "video-analytics"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}
variable "management_cidr" {
  description = "CIDR block allowed to SSH into the bastion host (e.g. your VPN or office egress IP)"
  type        = string
}
#--- EKS Node Groups ---

variable "node_instance_types" {
  description = "EC2 instance types for EKS worker nodes"
  type        = list(string)
  default     = ["m5.xlarge"]
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 6
}

variable "gpu_node_instance_types" {
  description = "EC2 GPU instance types for inference workloads"
  type        = list(string)
  default     = ["g4dn.xlarge"]
}

variable "gpu_node_desired_size" {
  description = "Desired number of GPU inference nodes"
  type        = number
  default     = 1
}

variable "gpu_node_min_size" {
  description = "Minimum number of GPU inference nodes"
  type        = number
  default     = 0
}

variable "gpu_node_max_size" {
  description = "Maximum number of GPU inference nodes"
  type        = number
  default     = 4
}

# --- S3 ---

variable "video_bucket_name" {
  description = "S3 bucket name for raw and processed video chunks"
  type        = string
}

variable "video_retention_days" {
  description = "Number of days to retain video in S3 before transitioning to Glacier"
  type        = number
  default     = 30
}

# TODO: Add variables for:
# - Node group instance types and sizing
# - S3 bucket names
# - Any other configurable parameters your infrastructure needs
