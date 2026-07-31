variable "aws_region" {
  type = string
}

variable "cluster_name" {
  type    = string
  default = "keycloak"
}

variable "k8s_version" {
  description = <<-EOT
    Kubernetes version. Find the newest with:
      aws eks describe-addon-versions --addon-name vpc-cni \
        --query 'addons[0].addonVersions[0].compatibilities[].clusterVersion' \
        --output text | tr '\t' '\n' | sort -V | tail -1
  EOT
  type        = string
  default     = "1.31"
}

# ---- FROM STACK 02 ---------------------------------------------------------
variable "cluster_role_arn" {
  description = "Output 'cluster_role_arn' of stack 02"
  type        = string
}

variable "node_role_arn" {
  description = "Output 'node_role_arn' of stack 02"
  type        = string
}

# ---- Your existing subnets -------------------------------------------------
variable "private_subnet_ids" {
  description = "Private subnet IDs in at least 2 AZs"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "EKS requires subnets in at least 2 Availability Zones."
  }
}

# ---- Auto Mode behaviour ---------------------------------------------------
variable "builtin_node_pools" {
  description = <<-EOT
    Built-in Auto Mode node pools to enable.

    []                                  = none, so ONLY the capped pool from
                                          stack 04 can create nodes. This is how
                                          "max 2 nodes" is actually enforced.
    ["general-purpose"]                 = AWS's default pool, NO size cap.
    ["general-purpose","system"]        = the full default setup.
  EOT
  type        = list(string)
  default     = []
}

# ---- API endpoint ----------------------------------------------------------
variable "endpoint_public_access" {
  description = "false = kubectl only works from inside the VPC (most secure, needed for air-gapped)"
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "If public access is on, restrict it to your office/VPN ranges"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "additional_admin_arns" {
  description = "Extra IAM user/role ARNs that should get cluster-admin"
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = { app = "keycloak", managed_by = "terraform" }
}
