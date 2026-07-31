# =============================================================================
# STACK 02 — IAM roles
#
# Fully independent: depends on NOTHING. Can be run before or after stack 01.
# Its outputs (two role ARNs) feed stack 03 (eks).
#
# Badge 1: CLUSTER role — worn by the EKS control plane. Auto Mode needs extra
#          policies so it can create nodes, disks and load balancers for you.
# Badge 2: NODE role — worn by every EC2 worker. Includes SSM as requested.
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

# ---------------------------------------------------------------------------
# CLUSTER ROLE
# Trust policy = "who may wear this badge?"  Answer: the EKS service.
# Auto Mode also requires sts:TagSession, not just sts:AssumeRole — a cluster
# created without it will fail to launch nodes.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "cluster_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name_prefix}-eks-cluster-role"
  description        = "EKS Auto Mode control plane role"
  assume_role_policy = data.aws_iam_policy_document.cluster_trust.json
  tags               = var.tags
}

locals {
  # Auto Mode needs all five: cluster basics, plus permission to manage
  # compute (nodes), block storage (EBS), load balancing, and networking.
  cluster_policies = [
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSComputePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy",
  ]

  # Minimal worker permissions + pull-only registry access + SSM.
  node_policies = concat([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    ],
    var.enable_ssm ? ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"] : []
  )
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each   = toset(local.cluster_policies)
  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# ---------------------------------------------------------------------------
# NODE ROLE
# Trust policy: the EC2 service, because nodes ARE EC2 instances.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "node_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name_prefix}-eks-node-role"
  description        = "EKS Auto Mode node role (SSM enabled)"
  assume_role_policy = data.aws_iam_policy_document.node_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each   = toset(local.node_policies)
  role       = aws_iam_role.node.name
  policy_arn = each.value
}
