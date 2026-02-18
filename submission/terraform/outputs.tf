output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id # Reference the VPC resource
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

output "nat_gateway_ip" {
  description = "Elastic IP address of the NAT Gateway (used for egress whitelisting)"
  value       = aws_eip.nat.public_ip
}

output "eks_cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = aws_eks_cluster.main.endpoint # Reference the EKS cluster resource
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = var.cluster_name
}
output "eks_cluster_ca_certificate" {
  description = "Base64-encoded certificate authority data for the EKS cluster"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "video_bucket_name" {
  description = "Name of the S3 bucket used for video storage"
  value       = aws_s3_bucket.video.id
}

output "video_bucket_arn" {
  description = "ARN of the S3 video bucket (for IAM policy references)"
  value       = aws_s3_bucket.video.arn
}

output "bastion_security_group_id" {
  description = "Security group ID for the bastion host"
  value       = aws_security_group.bastion.id
}

output "eks_nodes_security_group_id" {
  description = "Security group ID for EKS worker nodes"
  value       = aws_security_group.eks_nodes.id
}

# TODO: Add outputs for:
# - Private subnet IDs
# - Public subnet IDs
# - NAT Gateway IPs
# - S3 bucket names
# - Any other values downstream consumers need
