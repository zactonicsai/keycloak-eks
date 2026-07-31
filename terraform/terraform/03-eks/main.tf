# =============================================================================
# STACK 03 — EKS cluster with AUTO MODE
#
# Depends on: stack 02 (two IAM role ARNs) + your existing subnets.
# Its outputs feed stacks 04 (nodepool) and 05 (keycloak).
#
# Auto Mode = AWS runs the worker computers. Nodes appear when a pod needs one
# and vanish when it doesn't. You never patch or SSH into them.
#
# NOTE on node_pools: we set it to [] on purpose. The built-in "general-purpose"
# pool has NO size cap, which would defeat the "max 2 nodes" requirement.
# Stack 04 installs our own capped pool instead.
# =============================================================================
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.79" }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.k8s_version
  role_arn = var.cluster_role_arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
  }

  # --- The three switches that together mean "Auto Mode" --------------------
  # AWS requires all three enabled as a set; enabling only one is rejected.
  compute_config {
    enabled       = true
    node_role_arn = var.node_role_arn
    node_pools    = var.builtin_node_pools # [] so only our capped pool exists
  }

  storage_config {
    block_storage {
      enabled = true
    }
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  # Auto Mode ships its own networking/storage agents, so the legacy
  # self-managed addons (vpc-cni, kube-proxy, coredns) must NOT be installed.
  bootstrap_self_managed_addons = false

  # "API" = permissions come from EKS access entries (the modern way),
  # not from hand-editing the old aws-auth ConfigMap.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = merge(var.tags, { Name = var.cluster_name })
}

# ---------------------------------------------------------------------------
# Access entry for the NODE role.
# When you use the built-in node pools, EKS creates this automatically. Because
# we set node_pools = [] and bring our own NodeClass in stack 04, we must
# register the node role ourselves or nodes will never join the cluster.
# ---------------------------------------------------------------------------
resource "aws_eks_access_entry" "node" {
  count         = length(var.builtin_node_pools) == 0 ? 1 : 0
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.node_role_arn
  type          = "EC2"
}

resource "aws_eks_access_policy_association" "node" {
  count         = length(var.builtin_node_pools) == 0 ? 1 : 0
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.node_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAutoNodePolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.node]
}

# ---------------------------------------------------------------------------
# Optional: give another IAM principal (a teammate, a CI role) cluster admin.
# ---------------------------------------------------------------------------
resource "aws_eks_access_entry" "admins" {
  for_each      = toset(var.additional_admin_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admins" {
  for_each      = toset(var.additional_admin_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admins]
}
