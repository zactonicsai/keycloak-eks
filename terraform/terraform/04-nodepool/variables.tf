variable "aws_region" {
  type = string
}

# ---- FROM STACK 03 ---------------------------------------------------------
variable "cluster_name" {
  description = "Output 'cluster_name' of stack 03"
  type        = string
}

variable "cluster_security_group_id" {
  description = "Output 'cluster_security_group_id' of stack 03"
  type        = string
}

# ---- FROM STACK 02 ---------------------------------------------------------
variable "node_role_name" {
  description = "Output 'node_role_name' of stack 02 (NAME, not ARN)"
  type        = string
}

# ---- Your existing subnets -------------------------------------------------
variable "private_subnet_ids" {
  description = "Subnets nodes may launch into"
  type        = list(string)
}

# ---- The node cap ----------------------------------------------------------
variable "max_nodes" {
  description = "Hard ceiling on node count. Enforced as max_nodes x vcpu_per_node total vCPU."
  type        = number
  default     = 2
}

variable "vcpu_per_node" {
  description = "vCPU of each permitted instance type. Must match reality or the cap math breaks."
  type        = number
  default     = 2
}

variable "allowed_architectures" {
  description = "arm64 first = cheapest. Add amd64 if you run x86-only sidecars."
  type        = list(string)
  default     = ["arm64", "amd64"]
}

variable "instance_categories" {
  description = "c=compute, m=general, r=memory, t=burstable"
  type        = list(string)
  default     = ["c", "m", "r", "t"]
}

variable "capacity_types" {
  description = <<-EOT
    ["on-demand"]          = steady, full price.
    ["spot","on-demand"]   = up to ~70% cheaper, but AWS can reclaim a node with
                             2 minutes' notice. Fine for Keycloak only if you run
                             2+ replicas; risky at 1 replica.
  EOT
  type        = list(string)
  default     = ["on-demand"]
}

variable "consolidate_after" {
  description = "How long a node sits underused before Auto Mode removes it"
  type        = string
  default     = "5m"
}

variable "node_disk_size" {
  type    = string
  default = "40Gi"
}

variable "nodepool_name" {
  type    = string
  default = "keycloak-capped"
}

variable "nodeclass_name" {
  type    = string
  default = "keycloak-nodeclass"
}

variable "tags" {
  type    = map(string)
  default = { app = "keycloak", managed_by = "terraform" }
}
