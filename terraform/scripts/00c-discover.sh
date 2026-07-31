#!/usr/bin/env bash
# =============================================================================
# 00c-discover.sh — Find EVERY placeholder value using AWS CLI, then write a
# ready-to-use 00-env.generated.sh with the real values filled in.
#
# Middle-school version: instead of you hunting through the AWS web console for
# IDs, this asks AWS for them directly and fills out the form for you.
#
# Usage:
#   ./00c-discover.sh                 # auto-detect everything it can
#   ./00c-discover.sh vpc-0abc123     # if you already know which VPC to use
#
# Output: scripts/00-env.generated.sh   (review it, then rename to 00-env.sh)
# =============================================================================
set -euo pipefail
OUT="$(dirname "$0")/00-env.generated.sh"

# ---------------------------------------------------------------------------
# 1. REGION — what region is your CLI pointed at?
#    aws configure get region
# ---------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"
echo "==> Region: $AWS_REGION"

# ---------------------------------------------------------------------------
# 2. ACCOUNT ID + who am I?  (also proves your credentials work)
#    aws sts get-caller-identity
# ---------------------------------------------------------------------------
CALLER=$(aws sts get-caller-identity --output json)
ACCOUNT_ID=$(echo "$CALLER" | grep -o '"Account": *"[0-9]*"' | grep -o '[0-9]\{12\}')
echo "==> Account: $ACCOUNT_ID"
echo "    Identity: $(echo "$CALLER" | grep -o '"Arn": *"[^"]*"' | cut -d'"' -f4)"

# ---------------------------------------------------------------------------
# 3. VPC_ID — your existing VPC
#    aws ec2 describe-vpcs
# ---------------------------------------------------------------------------
if [[ $# -ge 1 ]]; then
  VPC_ID="$1"
else
  echo "==> VPCs found in $AWS_REGION:"
  aws ec2 describe-vpcs --region "$AWS_REGION" \
    --query 'Vpcs[].{VPC:VpcId,CIDR:CidrBlock,Default:IsDefault,Name:Tags[?Key==`Name`]|[0].Value}' \
    --output table
  # Prefer a NON-default VPC (default VPCs are all-public; bad for this build).
  VPC_ID=$(aws ec2 describe-vpcs --region "$AWS_REGION" \
    --filters "Name=isDefault,Values=false" \
    --query 'Vpcs[0].VpcId' --output text)
  [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]] && \
    VPC_ID=$(aws ec2 describe-vpcs --region "$AWS_REGION" --query 'Vpcs[0].VpcId' --output text)
  echo "    Auto-picked: $VPC_ID   (re-run with an argument to override)"
fi

# ---------------------------------------------------------------------------
# 4. VPC_CIDR — the IP range of that VPC (used to open the DB firewall)
#    aws ec2 describe-vpcs --vpc-ids <id> --query 'Vpcs[0].CidrBlock'
# ---------------------------------------------------------------------------
VPC_CIDR=$(aws ec2 describe-vpcs --region "$AWS_REGION" --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].CidrBlock' --output text)
echo "==> VPC CIDR: $VPC_CIDR"

# ---------------------------------------------------------------------------
# 5. PRIVATE_SUBNET_1 / _2 — two private subnets in two different AZs
#    aws ec2 describe-subnets  +  aws ec2 describe-route-tables
#    "Private" = its route table has NO 0.0.0.0/0 route to an igw-*.
# ---------------------------------------------------------------------------
is_public() {
  local s="$1" rtb igw
  rtb=$(aws ec2 describe-route-tables --region "$AWS_REGION" \
    --filters "Name=association.subnet-id,Values=$s" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
  if [[ "$rtb" == "None" || -z "$rtb" ]]; then
    rtb=$(aws ec2 describe-route-tables --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
      --query 'RouteTables[0].RouteTableId' --output text)
  fi
  igw=$(aws ec2 describe-route-tables --region "$AWS_REGION" --route-table-ids "$rtb" \
    --query "RouteTables[0].Routes[?starts_with(GatewayId||'','igw-')].GatewayId" --output text)
  [[ -n "$igw" && "$igw" != "None" ]]
}

echo "==> Scanning subnets in $VPC_ID"
declare -A PICKED_AZ=()
PRIVATE_SUBNET_1=""; PRIVATE_SUBNET_2=""
while read -r ID AZ CIDR FREE; do
  if is_public "$ID"; then TYPE="PUBLIC"; else TYPE="private"; fi
  printf "    %-26s %-14s %-20s free=%-6s %s\n" "$ID" "$AZ" "$CIDR" "$FREE" "$TYPE"
  # Pick the first private subnet per AZ, need >=8 free IPs, need 2 distinct AZs.
  if [[ "$TYPE" == "private" && "$FREE" -ge 8 && -z "${PICKED_AZ[$AZ]:-}" ]]; then
    PICKED_AZ[$AZ]="$ID"
    if   [[ -z "$PRIVATE_SUBNET_1" ]]; then PRIVATE_SUBNET_1="$ID"
    elif [[ -z "$PRIVATE_SUBNET_2" ]]; then PRIVATE_SUBNET_2="$ID"; fi
  fi
done < <(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].[SubnetId,AvailabilityZone,CidrBlock,AvailableIpAddressCount]' \
  --output text | sort -k2)

if [[ -z "$PRIVATE_SUBNET_2" ]]; then
  echo ""
  echo "!! Could not find TWO private subnets in TWO different AZs."
  echo "   RDS requires that. Options: create a second private subnet, or"
  echo "   fill PRIVATE_SUBNET_1/_2 by hand in the generated file."
  PRIVATE_SUBNET_1="${PRIVATE_SUBNET_1:-REPLACE-ME}"
  PRIVATE_SUBNET_2="REPLACE-ME"
else
  echo "==> Picked: $PRIVATE_SUBNET_1 and $PRIVATE_SUBNET_2"
fi

# ---------------------------------------------------------------------------
# 6. K8S_VERSION — newest Kubernetes version EKS supports right now
#    Trick: ask which cluster versions the vpc-cni addon is compatible with.
# ---------------------------------------------------------------------------
K8S_VERSION=$(aws eks describe-addon-versions --region "$AWS_REGION" \
  --addon-name vpc-cni \
  --query 'addons[0].addonVersions[0].compatibilities[].clusterVersion' \
  --output text 2>/dev/null | tr '\t' '\n' | sort -V | tail -1)
K8S_VERSION="${K8S_VERSION:-1.31}"
echo "==> Latest EKS Kubernetes version: $K8S_VERSION"

# ---------------------------------------------------------------------------
# 7. DB_ENGINE_VERSION — newest PostgreSQL major version RDS offers
#    aws rds describe-db-engine-versions --engine postgres
# ---------------------------------------------------------------------------
DB_ENGINE_VERSION=$(aws rds describe-db-engine-versions --region "$AWS_REGION" \
  --engine postgres --query 'DBEngineVersions[].EngineVersion' --output text \
  | tr '\t' '\n' | cut -d. -f1 | sort -n | tail -1)
DB_ENGINE_VERSION="${DB_ENGINE_VERSION:-16}"
echo "==> Latest RDS PostgreSQL major version: $DB_ENGINE_VERSION"

# ---------------------------------------------------------------------------
# 8. DB_INSTANCE_CLASS — is the cheap ARM class available in this region?
#    aws rds describe-orderable-db-instance-options
# ---------------------------------------------------------------------------
DB_INSTANCE_CLASS="db.t4g.micro"
if ! aws rds describe-orderable-db-instance-options --region "$AWS_REGION" \
     --engine postgres --db-instance-class db.t4g.micro \
     --query 'OrderableDBInstanceOptions[0]' --output text 2>/dev/null | grep -q .; then
  DB_INSTANCE_CLASS="db.t3.micro"
  echo "==> db.t4g.micro unavailable here; falling back to db.t3.micro"
else
  echo "==> db.t4g.micro is available (cheapest choice)"
fi

# ---------------------------------------------------------------------------
# 9. PASSWORDS — let AWS generate strong ones for you
#    aws secretsmanager get-random-password
#    (Excluded chars: / @ " and space, which RDS forbids in master passwords.)
# ---------------------------------------------------------------------------
gen_pw() {
  aws secretsmanager get-random-password --region "$AWS_REGION" \
    --password-length 28 --require-each-included-type \
    --exclude-characters '/@" '"'" \
    --query RandomPassword --output text 2>/dev/null \
  || openssl rand -base64 24 | tr -d '/@"= '
}
DB_PASSWORD=$(gen_pw)
KC_ADMIN_PASSWORD=$(gen_pw)
echo "==> Generated two strong passwords"

# ---------------------------------------------------------------------------
# 10. CLUSTER_NAME — make sure the name isn't taken
#     aws eks list-clusters
# ---------------------------------------------------------------------------
CLUSTER_NAME="keycloak"
if aws eks list-clusters --region "$AWS_REGION" --query 'clusters' --output text \
   | tr '\t' '\n' | grep -qx "$CLUSTER_NAME"; then
  CLUSTER_NAME="keycloak-$(date +%m%d)"
  echo "==> 'keycloak' already exists; using $CLUSTER_NAME"
fi

# ---------------------------------------------------------------------------
# 11. IAM role name collisions
#     aws iam list-roles
# ---------------------------------------------------------------------------
for R in keycloak-eks-cluster-role keycloak-eks-node-role; do
  aws iam get-role --role-name "$R" >/dev/null 2>&1 && \
    echo "!! IAM role $R already exists — 02-iam-roles.sh will error; delete or rename it."
done

# ---------------------------------------------------------------------------
# Write the filled-in env file
# ---------------------------------------------------------------------------
cat > "$OUT" <<EOF
#!/usr/bin/env bash
# Generated by 00c-discover.sh on $(date -u '+%Y-%m-%d %H:%M UTC')
# Review, then:  mv 00-env.generated.sh 00-env.sh

export AWS_REGION="$AWS_REGION"
export CLUSTER_NAME="$CLUSTER_NAME"
export K8S_VERSION="$K8S_VERSION"

export VPC_ID="$VPC_ID"
export PRIVATE_SUBNET_1="$PRIVATE_SUBNET_1"
export PRIVATE_SUBNET_2="$PRIVATE_SUBNET_2"
export VPC_CIDR="$VPC_CIDR"

export DB_INSTANCE_ID="keycloak-db"
export DB_NAME="keycloak"
export DB_USERNAME="keycloak"
export DB_PASSWORD='$DB_PASSWORD'
export DB_INSTANCE_CLASS="$DB_INSTANCE_CLASS"
export DB_ENGINE_VERSION="$DB_ENGINE_VERSION"
export DB_STORAGE_GB="20"

# Not an AWS value — check https://www.keycloak.org/downloads for the newest 26.x
export KC_VERSION="26.6.1"
export KC_ADMIN_PASSWORD='$KC_ADMIN_PASSWORD'
export KC_NAMESPACE="keycloak"

# Not AWS values — these come from your Artifactory admin.
# Best practice: keep the password in SSM Parameter Store instead (see below).
export OFFLINE="false"
export ARTIFACTORY_HOST="artifactory.mycompany.com"
export ARTIFACTORY_DOCKER_REPO="docker-local"
export ARTIFACTORY_HELM_REPO="helm-local"
export ARTIFACTORY_USER="deploy-user"
export ARTIFACTORY_PASSWORD="\${ARTIFACTORY_PASSWORD:-CHANGE-ME}"
# To pull it from SSM instead of hard-coding:
# export ARTIFACTORY_PASSWORD=\$(aws ssm get-parameter --region $AWS_REGION \\
#   --name /keycloak/artifactory/password --with-decryption \\
#   --query Parameter.Value --output text)

export ACCOUNT_ID="$ACCOUNT_ID"
EOF

chmod 600 "$OUT"
echo ""
echo "WROTE: $OUT  (chmod 600 — it holds passwords)"
echo "Next:  review it, then  mv $OUT $(dirname "$0")/00-env.sh"
echo "Then:  ./00b-find-subnets.sh check"
