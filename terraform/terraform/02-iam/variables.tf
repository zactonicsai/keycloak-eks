variable "aws_region" {
  description = "AWS region (IAM is global, but the provider needs one)"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for role names"
  type        = string
  default     = "keycloak"
}

variable "enable_ssm" {
  description = <<-EOT
    Attach AmazonSSMManagedInstanceCore to the node role.

    Honest caveat: EKS Auto Mode nodes are locked-down Bottlerocket machines that
    AWS manages, and AWS discourages interactive logins to them. The permission
    is here and correct, but the supported way to inspect a node is
    'kubectl debug node/<name>'. Set false if your security policy forbids
    unused permissions.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = { app = "keycloak", managed_by = "terraform" }
}
