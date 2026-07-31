# These outputs become the tfvars for STACK 05 (keycloak).
output "rds_endpoint" {
  description = "Hostname Keycloak connects to"
  value       = aws_db_instance.this.address
}

output "rds_port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

output "db_username" {
  value = aws_db_instance.this.username
}

output "db_password_ssm_path" {
  description = "Where stack 05 reads the password from"
  value       = aws_ssm_parameter.db_password.name
}

output "db_security_group_id" {
  value = aws_security_group.db.id
}

output "jdbc_url" {
  description = "Handy for debugging with psql/JDBC"
  value       = "jdbc:postgresql://${aws_db_instance.this.address}:${aws_db_instance.this.port}/${aws_db_instance.this.db_name}"
}
