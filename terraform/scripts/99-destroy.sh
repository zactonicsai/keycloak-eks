#!/usr/bin/env bash
# =============================================================================
# 99-destroy.sh — Tear down EVERYTHING this tutorial created.
#
# Safe to run twice. Safe to run after a half-finished build. Every step asks
# "does this still exist?" first, and a missing resource is treated as success,
# not as an error.
#
# ORDER MATTERS — it's the reverse of how things were built, because AWS won't
# let you delete something that another thing is still holding onto:
#   1. Kubernetes load balancers  (they hold network interfaces in your subnets)
#   2. Helm release + namespace
#   3. EKS cluster                (this terminates the Auto Mode nodes)
#   4. CloudWatch log group
#   5. IAM roles                  (detach policies + instance profiles first)
#   6. RDS instance               (holds network interfaces in the DB subnets)
#   7. DB subnet group            (can't go until the database is gone)
#   8. Security group             (can't go until the database is gone)
#
# Usage:
#   ./99-destroy.sh                 # asks you to type DESTROY
#   ./99-destroy.sh --yes           # no prompt (for automation)
#   ./99-destroy.sh --snapshot      # keep a final RDS snapshot before deleting
#   ./99-destroy.sh --keep-db       # tear down EKS/IAM but LEAVE the database
# =============================================================================
set -uo pipefail          # NOTE: no '-e' on purpose — we want to keep going.
source "$(dirname "$0")/00-env.sh"

CONFIRM=true; SNAPSHOT=false; KEEP_DB=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y)    CONFIRM=false ;;
    --snapshot)  SNAPSHOT=true ;;
    --keep-db)   KEEP_DB=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# --- Pretty helpers ---------------------------------------------------------
step() { echo ""; echo "=== $* ==="; }
ok()   { echo "    [done]    $*"; }
skip() { echo "    [skipped] $*"; }
warn() { echo "    [warn]    $*"; }

# ---------------------------------------------------------------------------
# Confirmation — this deletes real data.
# ---------------------------------------------------------------------------
cat <<EOF
About to destroy, in region $AWS_REGION:
  EKS cluster ......... $CLUSTER_NAME
  IAM roles ........... keycloak-eks-cluster-role, keycloak-eks-node-role
  RDS instance ........ $DB_INSTANCE_ID $( $KEEP_DB && echo '(KEPT — --keep-db)' )
  DB subnet group ..... keycloak-db-subnets
  Security group ...... keycloak-db-sg
Your VPC and subnets are NOT touched (they existed before this tutorial).
EOF
if $CONFIRM; then
  read -r -p 'Type DESTROY to continue: ' REPLY
  [[ "$REPLY" == "DESTROY" ]] || { echo "Aborted."; exit 1; }
fi

# ===========================================================================
step "1/8  Kubernetes load balancers and the Helm release"
# Why first: an AWS load balancer created by a Service or Ingress plants network
# interfaces in your subnets. Delete the cluster with those still around and the
# load balancers are orphaned — they keep billing you and block subnet cleanup.
# ===========================================================================
if aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1; then
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1

  if kubectl get ns "$KC_NAMESPACE" >/dev/null 2>&1; then
    # Ingresses first, then LoadBalancer Services.
    kubectl -n "$KC_NAMESPACE" delete ingress --all --ignore-not-found --timeout=5m >/dev/null 2>&1 \
      && ok "ingresses deleted"
    LBS=$(kubectl -n "$KC_NAMESPACE" get svc \
          -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    if [[ -n "$LBS" ]]; then
      echo "$LBS" | xargs -r -n1 kubectl -n "$KC_NAMESPACE" delete svc --timeout=5m >/dev/null 2>&1
      ok "LoadBalancer services deleted"
      echo "    waiting 60s for AWS to release the load balancers..."
      sleep 60
    else
      skip "no LoadBalancer services (you used port-forward — nothing to clean)"
    fi

    helm uninstall keycloak -n "$KC_NAMESPACE" --wait --timeout 10m >/dev/null 2>&1 \
      && ok "helm release 'keycloak' uninstalled" \
      || skip "helm release not found"

    # PVCs would otherwise leave EBS volumes behind, billing quietly.
    kubectl -n "$KC_NAMESPACE" delete pvc --all --ignore-not-found --timeout=5m >/dev/null 2>&1 \
      && ok "persistent volume claims deleted"

    kubectl delete namespace "$KC_NAMESPACE" --ignore-not-found --timeout=10m >/dev/null 2>&1 \
      && ok "namespace $KC_NAMESPACE deleted"
  else
    skip "namespace $KC_NAMESPACE not found"
  fi

  kubectl delete -f "$(dirname "$0")/../nodepool.yaml" --ignore-not-found >/dev/null 2>&1 \
    && ok "NodePool deleted"
else
  skip "cluster $CLUSTER_NAME not found — nothing to uninstall"
fi

# ===========================================================================
step "2/8  EKS cluster (this terminates the Auto Mode nodes for you)"
# ===========================================================================
if aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1; then
  # Any classic managed node groups must go before the cluster. Auto Mode has
  # none, but a hand-made one would block deletion, so check anyway.
  for NG in $(aws eks list-nodegroups --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
              --query 'nodegroups[]' --output text 2>/dev/null); do
    aws eks delete-nodegroup --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
      --nodegroup-name "$NG" >/dev/null 2>&1
    aws eks wait nodegroup-deleted --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" \
      --nodegroup-name "$NG" 2>/dev/null
    ok "nodegroup $NG deleted"
  done

  aws eks delete-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1
  echo "    waiting for cluster deletion (~5-10 min)..."
  aws eks wait cluster-deleted --region "$AWS_REGION" --name "$CLUSTER_NAME" 2>/dev/null
  ok "cluster $CLUSTER_NAME deleted"

  kubectl config delete-context "arn:aws:eks:${AWS_REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}" >/dev/null 2>&1
  kubectl config delete-cluster "arn:aws:eks:${AWS_REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}" >/dev/null 2>&1
  ok "kubeconfig entries removed"
else
  skip "cluster $CLUSTER_NAME already gone"
fi

# ===========================================================================
step "3/8  CloudWatch log group"
# Deleting a cluster does NOT delete its logs. They bill until you remove them.
# ===========================================================================
LG="/aws/eks/${CLUSTER_NAME}/cluster"
if aws logs describe-log-groups --region "$AWS_REGION" --log-group-name-prefix "$LG" \
   --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -qx "$LG"; then
  aws logs delete-log-group --region "$AWS_REGION" --log-group-name "$LG" >/dev/null 2>&1 \
    && ok "log group $LG deleted"
else
  skip "no log group $LG"
fi

# ===========================================================================
step "4/8  IAM roles"
# A role can't be deleted while policies are attached or an instance profile
# still references it. So: detach managed, delete inline, unhook profiles, THEN
# delete the role.
# ===========================================================================
delete_role() {
  local ROLE="$1"
  if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
    skip "role $ROLE already gone"; return
  fi
  for ARN in $(aws iam list-attached-role-policies --role-name "$ROLE" \
               --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$ARN" >/dev/null 2>&1
  done
  for P in $(aws iam list-role-policies --role-name "$ROLE" \
             --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$ROLE" --policy-name "$P" >/dev/null 2>&1
  done
  for IP in $(aws iam list-instance-profiles-for-role --role-name "$ROLE" \
              --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null); do
    aws iam remove-role-from-instance-profile --instance-profile-name "$IP" --role-name "$ROLE" >/dev/null 2>&1
    aws iam delete-instance-profile --instance-profile-name "$IP" >/dev/null 2>&1
  done
  aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 \
    && ok "role $ROLE deleted" \
    || warn "could not delete $ROLE — check for leftover attachments"
}
delete_role keycloak-eks-cluster-role
delete_role keycloak-eks-node-role

# ===========================================================================
step "5/8  RDS instance"
# ===========================================================================
if $KEEP_DB; then
  skip "--keep-db given, leaving $DB_INSTANCE_ID alone"
elif aws rds describe-db-instances --region "$AWS_REGION" \
     --db-instance-identifier "$DB_INSTANCE_ID" >/dev/null 2>&1; then

  # Deletion protection would reject the delete with a confusing error.
  PROT=$(aws rds describe-db-instances --region "$AWS_REGION" \
         --db-instance-identifier "$DB_INSTANCE_ID" \
         --query 'DBInstances[0].DeletionProtection' --output text 2>/dev/null)
  if [[ "$PROT" == "True" ]]; then
    aws rds modify-db-instance --region "$AWS_REGION" \
      --db-instance-identifier "$DB_INSTANCE_ID" \
      --no-deletion-protection --apply-immediately >/dev/null 2>&1
    ok "deletion protection turned off"
    sleep 15
  fi

  if $SNAPSHOT; then
    SNAP="${DB_INSTANCE_ID}-final-$(date +%Y%m%d%H%M)"
    aws rds delete-db-instance --region "$AWS_REGION" \
      --db-instance-identifier "$DB_INSTANCE_ID" \
      --final-db-snapshot-identifier "$SNAP" >/dev/null 2>&1
    ok "deleting with final snapshot: $SNAP (this snapshot keeps costing a little)"
  else
    aws rds delete-db-instance --region "$AWS_REGION" \
      --db-instance-identifier "$DB_INSTANCE_ID" \
      --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1
    ok "deleting with NO snapshot — all Keycloak users/realms are gone forever"
  fi

  echo "    waiting for the database to disappear (~5-10 min)..."
  aws rds wait db-instance-deleted --region "$AWS_REGION" \
    --db-instance-identifier "$DB_INSTANCE_ID" 2>/dev/null
  ok "RDS instance $DB_INSTANCE_ID deleted"
else
  skip "RDS instance $DB_INSTANCE_ID already gone"
fi

# ===========================================================================
step "6/8  DB subnet group"
# ===========================================================================
if $KEEP_DB; then
  skip "--keep-db given"
elif aws rds describe-db-subnet-groups --region "$AWS_REGION" \
     --db-subnet-group-name keycloak-db-subnets >/dev/null 2>&1; then
  aws rds delete-db-subnet-group --region "$AWS_REGION" \
    --db-subnet-group-name keycloak-db-subnets >/dev/null 2>&1 \
    && ok "subnet group keycloak-db-subnets deleted" \
    || warn "still in use — a database may still be shutting down; rerun in a few minutes"
else
  skip "subnet group already gone"
fi

# ===========================================================================
step "7/8  Security group"
# AWS keeps the group alive until every network interface using it is released,
# which lags the database deletion by a minute or two. So we retry.
# ===========================================================================
if $KEEP_DB; then
  skip "--keep-db given"
else
  SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
          --filters "Name=group-name,Values=keycloak-db-sg" "Name=vpc-id,Values=$VPC_ID" \
          --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
  if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
    for ATTEMPT in 1 2 3 4 5 6; do
      if aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$SG_ID" >/dev/null 2>&1; then
        ok "security group $SG_ID deleted"; break
      fi
      [[ $ATTEMPT -eq 6 ]] && warn "could not delete $SG_ID — something still uses it; rerun this script later"
      echo "    still in use, retrying in 30s ($ATTEMPT/6)..."
      sleep 30
    done
  else
    skip "security group keycloak-db-sg already gone"
  fi
fi

# ===========================================================================
step "8/8  Leftover check — anything still costing money?"
# ===========================================================================
echo "  EKS clusters:"
aws eks list-clusters --region "$AWS_REGION" --query 'clusters' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/    /'
echo "  RDS instances:"
aws rds describe-db-instances --region "$AWS_REGION" \
  --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus]' --output text 2>/dev/null | sed 's/^/    /'
echo "  RDS snapshots (manual snapshots keep billing):"
aws rds describe-db-snapshots --region "$AWS_REGION" --snapshot-type manual \
  --query 'DBSnapshots[].DBSnapshotIdentifier' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/    /'
echo "  Load balancers in your VPC:"
aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --query "LoadBalancers[?VpcId=='$VPC_ID'].[LoadBalancerName,Type]" --output text 2>/dev/null | sed 's/^/    /'
echo "  Unattached EBS volumes (orphans from PVCs):"
aws ec2 describe-volumes --region "$AWS_REGION" --filters "Name=status,Values=available" \
  --query 'Volumes[].[VolumeId,Size,CreateTime]' --output text 2>/dev/null | sed 's/^/    /'
echo "  EC2 instances still tagged for this cluster:"
aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER_NAME" \
            "Name=instance-state-name,Values=running,pending,stopping,stopped" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text 2>/dev/null | sed 's/^/    /'

cat <<EOF

=== Teardown finished ===
Blank sections above mean nothing is left. If a warning appeared, just run this
script again in a few minutes — AWS releases some resources on a delay, and the
script picks up exactly where it stopped.

Not touched (they were yours to begin with): the VPC, its subnets, route tables,
NAT gateways, and anything in SSM Parameter Store.
To remove stored passwords too:
  aws ssm delete-parameter --region $AWS_REGION --name /keycloak/db/password
  aws ssm delete-parameter --region $AWS_REGION --name /keycloak/artifactory/password
EOF
