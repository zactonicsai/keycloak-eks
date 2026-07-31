# These outputs become the tfvars for STACK 03 (eks) and STACK 04 (nodepool).
output "cluster_role_arn" {
  description = "Feed into stack 03 as cluster_role_arn"
  value       = aws_iam_role.cluster.arn
}

output "node_role_arn" {
  description = "Feed into stack 03 as node_role_arn"
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "Stack 04's NodeClass needs the NAME, not the ARN"
  value       = aws_iam_role.node.name
}

output "ssm_enabled" {
  value = var.enable_ssm
}
