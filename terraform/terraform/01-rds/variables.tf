variable "aws_region" {
  description = "AWS region, e.g. us-east-1"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for every resource name"
  type        = string
  default     = "keycloak"
}

# ---- Your EXISTING VPC (read-only to this stack) ---------------------------
variable "vpc_id" {
  description = "ID of the VPC that already exists"
  type        = string
}

variable "private_subnet_ids" {
  description = "Two or more PRIVATE subnet IDs in DIFFERENT Availability Zones"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "RDS needs at least 2 subnets, in 2 different Availability Zones."
  }
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach port 5432. Defaults to the VPC's own CIDR."
  type        = string
  default     = null
}

# ---- Database settings -----------------------------------------------------
variable "db_name" {
  description = "Name of the database Keycloak will use"
  type        = string
  default     = "keycloak"
}

variable "db_username" {
  description = "Master username"
  type        = string
  default     = "keycloak"
}

variable "db_password_ssm_path" {
  description = "SSM Parameter Store path where the generated password is kept"
  type        = string
  default     = "/keycloak/db/password"
}

variable "engine_version" {
  description = "PostgreSQL MAJOR version, e.g. 16"
  type        = string
  default     = "16"
}

variable "instance_class" {
  description = "db.t4g.micro is cheapest (ARM). Use db.t3.micro if t4g is unavailable."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Storage in GB"
  type        = number
  default     = 20
}

variable "multi_az" {
  description = "true = hot standby in another AZ, roughly double the cost"
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Days of automated backups. 0 disables them (not recommended)."
  type        = number
  default     = 1
}

variable "skip_final_snapshot" {
  description = "true = destroy leaves no snapshot behind"
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "true blocks terraform destroy until you turn it off"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to everything"
  type        = map(string)
  default     = { app = "keycloak", managed_by = "terraform" }
}
