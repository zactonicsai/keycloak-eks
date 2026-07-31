output "nodepool_name" {
  value = var.nodepool_name
}

output "nodeclass_name" {
  value = var.nodeclass_name
}

output "max_nodes" {
  description = "Ceiling this stack enforces"
  value       = var.max_nodes
}

output "cpu_limit" {
  description = "The actual Karpenter limit that creates the ceiling"
  value       = "${var.max_nodes * var.vcpu_per_node} vCPU"
}

output "verify_command" {
  value = "kubectl get nodepool ${var.nodepool_name} -o yaml"
}
