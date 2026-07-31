variable "aws_region" {
  type = string
}

# ---- FROM STACK 03 ---------------------------------------------------------
variable "cluster_name" {
  description = "Output 'cluster_name' of stack 03"
  type        = string
}

# ---- FROM STACK 01 ---------------------------------------------------------
variable "rds_endpoint" {
  description = "Output 'rds_endpoint' of stack 01"
  type        = string
}

variable "rds_port" {
  type    = number
  default = 5432
}

variable "db_name" {
  type    = string
  default = "keycloak"
}

variable "db_username" {
  type    = string
  default = "keycloak"
}

variable "db_password_ssm_path" {
  description = "Output 'db_password_ssm_path' of stack 01. The password is READ from here."
  type        = string
  default     = "/keycloak/db/password"
}

# ---- Keycloak --------------------------------------------------------------
variable "namespace" {
  type    = string
  default = "keycloak"
}

variable "keycloak_version" {
  description = "Image tag. Check https://www.keycloak.org/downloads for the newest 26.x"
  type        = string
  default     = "26.6.1"
}

variable "chart_version" {
  description = "keycloakx chart version. null = newest available."
  type        = string
  default     = null
}

variable "replicas" {
  description = "1 is cheapest. Use 2+ for high availability (and before using spot nodes)."
  type        = number
  default     = 1
}

variable "memory_limit" {
  type    = string
  default = "1280Mi"
}

variable "admin_username" {
  type    = string
  default = "admin"
}

variable "admin_password_ssm_path" {
  description = "Where the generated admin password is saved for you to retrieve"
  type        = string
  default     = "/keycloak/admin/password"
}

variable "hostname_strict" {
  description = <<-EOT
    false = relaxed hostname checks, fine while testing with port-forward.
    true  = Keycloak insists on a real configured hostname. Set true (and set
            ingress_hostname) before letting real users in.
  EOT
  type        = bool
  default     = false
}

# ---- Exposure (costs money) ------------------------------------------------
variable "ingress_enabled" {
  description = "false = no load balancer, $0. Reach Keycloak with kubectl port-forward."
  type        = bool
  default     = false
}

variable "ingress_internal" {
  description = "true = VPC-internal load balancer (safer). false = internet-facing."
  type        = bool
  default     = true
}

variable "ingress_hostname" {
  type    = string
  default = "keycloak.internal"
}

# ---- Offline / Artifactory -------------------------------------------------
variable "offline_mode" {
  description = "true = pull the image and chart from Artifactory instead of the internet"
  type        = bool
  default     = false
}

variable "artifactory_host" {
  type    = string
  default = ""
}

variable "artifactory_docker_repo" {
  type    = string
  default = "docker-local"
}

variable "artifactory_helm_repo" {
  type    = string
  default = "helm-local"
}

variable "artifactory_username" {
  type    = string
  default = ""
}

variable "artifactory_password" {
  description = "Best practice: don't put this in tfvars. Use TF_VAR_artifactory_password, or read it from SSM."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  type    = map(string)
  default = { app = "keycloak", managed_by = "terraform" }
}
