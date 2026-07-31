# These outputs become the tfvars for STACK 04 (nodepool) and STACK 05 (keycloak).
output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority" {
  value     = aws_eks_cluster.this.certificate_authority[0].data
  sensitive = true
}

output "cluster_security_group_id" {
  description = "The SG EKS made for the cluster. Stack 04's NodeClass selects on it."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "cluster_version" {
  value = aws_eks_cluster.this.version
}

output "oidc_issuer_url" {
  description = "For wiring IAM Roles for Service Accounts later"
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name}"
}
