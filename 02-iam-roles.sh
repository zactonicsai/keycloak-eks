#!/usr/bin/env bash
# =============================================================================
# 02-iam-roles.sh — Make the two "permission badges" (IAM roles).
#   Badge 1: CLUSTER role — worn by the EKS brain. Auto Mode needs extra
#            policies so it can create/destroy nodes, disks, load balancers.
#   Badge 2: NODE role — worn by every EC2 worker. Includes SSM
#            (AmazonSSMManagedInstanceCore) as requested.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-env.sh"

echo "==> 1/2 Cluster role"
# Trust policy = "who may wear this badge?" Answer: the EKS service.
# Auto Mode ALSO requires sts:TagSession, not just sts:AssumeRole.
cat > /tmp/eks-cluster-trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "eks.amazonaws.com" },
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}
EOF

aws iam create-role \
  --role-name keycloak-eks-cluster-role \
  --assume-role-policy-document file:///tmp/eks-cluster-trust.json

for POLICY in AmazonEKSClusterPolicy AmazonEKSComputePolicy \
              AmazonEKSBlockStoragePolicy AmazonEKSLoadBalancingPolicy \
              AmazonEKSNetworkingPolicy; do
  aws iam attach-role-policy \
    --role-name keycloak-eks-cluster-role \
    --policy-arn "arn:aws:iam::aws:policy/$POLICY"
done

echo "==> 2/2 Node role (with SSM)"
cat > /tmp/eks-node-trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name keycloak-eks-node-role \
  --assume-role-policy-document file:///tmp/eks-node-trust.json

# Minimal node permissions + pull-only ECR + SSM (your requirement).
for POLICY in AmazonEKSWorkerNodeMinimalPolicy \
              AmazonEC2ContainerRegistryPullOnly \
              AmazonSSMManagedInstanceCore; do
  aws iam attach-role-policy \
    --role-name keycloak-eks-node-role \
    --policy-arn "arn:aws:iam::aws:policy/$POLICY"
done

echo ""
echo "DONE. Role ARNs (the next script looks these up automatically):"
aws iam get-role --role-name keycloak-eks-cluster-role --query Role.Arn --output text
aws iam get-role --role-name keycloak-eks-node-role --query Role.Arn --output text
