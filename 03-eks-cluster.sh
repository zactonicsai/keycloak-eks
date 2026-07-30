#!/usr/bin/env bash
# =============================================================================
# 03-eks-cluster.sh — Create the EKS AUTO MODE cluster in your existing VPC,
# then apply nodepool.yaml which enforces "min 1 / max 2 small nodes".
# Auto Mode = AWS runs the worker computers for you (no patching, no SSH).
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-env.sh"

CLUSTER_ROLE_ARN=$(aws iam get-role --role-name keycloak-eks-cluster-role --query Role.Arn --output text)
NODE_ROLE_ARN=$(aws iam get-role --role-name keycloak-eks-node-role --query Role.Arn --output text)

echo "==> 1/3 Creating cluster (Auto Mode ON). Takes ~10-12 minutes."
# Auto Mode rule: compute + storage + load balancing must ALL be enabled together.
# nodePools=general-purpose gives a built-in pool; our own nodepool.yaml adds the cap.
aws eks create-cluster \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME" \
  --kubernetes-version "$K8S_VERSION" \
  --role-arn "$CLUSTER_ROLE_ARN" \
  --resources-vpc-config "subnetIds=$PRIVATE_SUBNET_1,$PRIVATE_SUBNET_2" \
  --compute-config "enabled=true,nodeRoleArn=$NODE_ROLE_ARN,nodePools=general-purpose" \
  --kubernetes-network-config '{"elasticLoadBalancing":{"enabled":true}}' \
  --storage-config '{"blockStorage":{"enabled":true}}'

aws eks wait cluster-active --region "$AWS_REGION" --name "$CLUSTER_NAME"

echo "==> 2/3 Pointing kubectl at the new cluster"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
kubectl get svc   # quick smoke test — should list the 'kubernetes' service

echo "==> 3/3 Applying the size-capped NodePool (this is the 'max 2 nodes' part)"
kubectl apply -f "$(dirname "$0")/../nodepool.yaml"

# Optional: turn OFF the built-in unlimited pool so ONLY our capped pool is used.
# (The built-in 'general-purpose' pool has no size cap.)
aws eks update-cluster-config \
  --region "$AWS_REGION" --name "$CLUSTER_NAME" \
  --compute-config "enabled=true,nodeRoleArn=$NODE_ROLE_ARN,nodePools=[]" || true

echo ""
echo "DONE. Nodes will appear only when a pod needs one (that's Auto Mode)."
echo "Watch with: kubectl get nodes -w"
