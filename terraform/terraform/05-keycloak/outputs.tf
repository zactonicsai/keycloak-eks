output "namespace" {
  value = kubernetes_namespace.this.metadata[0].name
}

output "helm_release_status" {
  value = helm_release.keycloak.status
}

output "admin_username" {
  value = var.admin_username
}

output "admin_password_command" {
  description = "Run this to read the generated admin password"
  value       = "aws ssm get-parameter --region ${var.aws_region} --name ${var.admin_password_ssm_path} --with-decryption --query Parameter.Value --output text"
}

output "port_forward_command" {
  description = "Free way to reach the login page — no load balancer needed"
  value       = "kubectl -n ${var.namespace} port-forward svc/keycloak-keycloakx-http 8080:80"
}

output "database_jdbc_url" {
  value = "jdbc:postgresql://${var.rds_endpoint}:${var.rds_port}/${var.db_name}"
}
