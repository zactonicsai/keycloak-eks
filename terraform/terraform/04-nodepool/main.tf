# =============================================================================
# STACK 04 — NodeClass + NodePool  (this is the "min 1 / max 2 nodes" stack)
#
# Depends on: stack 03 (cluster name) + stack 02 (node role NAME) + subnets.
#
# HOW THE NODE CAP ACTUALLY WORKS
# EKS Auto Mode has no "maximum node count" setting. It uses Karpenter, which
# caps a pool by TOTAL CPU and memory. So we do the equivalent:
#   * allow only 2-vCPU instance types
#   * cap the pool at 4 vCPU
#   4 vCPU total / 2 vCPU per machine = AT MOST 2 NODES.
# "Min 1" needs no setting: while the Keycloak pod exists, one node must exist
# to hold it. Scale Keycloak to 0 replicas and nodes drop to 0, saving money.
# =============================================================================
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws        = { source = "hashicorp/aws", version = ">= 5.79" }
    kubernetes = { source = "hashicorp/kubernetes", version = ">= 2.32" }
  }
}

provider "aws" {
  region = var.aws_region
}

# Read the cluster that stack 03 built, so we can talk to its API.
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

# Auth by shelling out to the AWS CLI — tokens last 15 minutes, so this avoids
# the classic "expired token" failure of the older data.aws_eks_cluster_auth.
provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.aws_region]
  }
}

# ---------------------------------------------------------------------------
# NodeClass — the "what kind of machine" template: which role it wears, which
# subnets it may sit in, which firewall it gets, how big its disk is.
# Needed because stack 03 disabled the built-in pools (and their default class).
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "nodeclass" {
  manifest = {
    apiVersion = "eks.amazonaws.com/v1"
    kind       = "NodeClass"
    metadata = {
      name = var.nodeclass_name
    }
    spec = {
      role = var.node_role_name # the NAME, not the ARN

      subnetSelectorTerms = [
        for s in var.private_subnet_ids : { id = s }
      ]

      securityGroupSelectorTerms = [
        { id = var.cluster_security_group_id }
      ]

      ephemeralStorage = {
        size       = var.node_disk_size
        iops       = 3000
        throughput = 125
      }

      tags = var.tags
    }
  }
}

# ---------------------------------------------------------------------------
# NodePool — the "how many and which sizes" rules.
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "nodepool" {
  manifest = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = var.nodepool_name
    }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            group = "eks.amazonaws.com"
            kind  = "NodeClass"
            name  = var.nodeclass_name
          }

          requirements = [
            {
              # arm64 (Graviton) is ~20% cheaper and the official Keycloak
              # image is multi-arch, so it runs fine there.
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = var.allowed_architectures
            },
            {
              key      = "eks.amazonaws.com/instance-category"
              operator = "In"
              values   = var.instance_categories
            },
            {
              # Only 2-vCPU machines, which turns the CPU cap below into a
              # node-count cap. Change this and the math changes with it.
              key      = "eks.amazonaws.com/instance-cpu"
              operator = "In"
              values   = [tostring(var.vcpu_per_node)]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = var.capacity_types
            },
          ]
        }
      }

      # THE CAP: max_nodes x vcpu_per_node total vCPU.
      limits = {
        cpu    = tostring(var.max_nodes * var.vcpu_per_node)
        memory = "${var.max_nodes * var.vcpu_per_node * 8}Gi"
      }

      disruption = {
        # Shrink back down when load drops — this is what returns you to 1 node.
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = var.consolidate_after
      }
    }
  }

  depends_on = [kubernetes_manifest.nodeclass]
}
