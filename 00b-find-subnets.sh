#!/usr/bin/env bash
# =============================================================================
# 00b-find-subnets.sh — Find the REAL subnet IDs in your existing VPC, and
# check they satisfy the rules before you try to build anything.
#
# Why this exists: 00-env.sh ships with FAKE example IDs (subnet-aaaa1111).
# If you run 01-rds-postgres.sh without replacing them, AWS replies:
#   "Some input subnets in [...] are invalid."
#
# The rules your two subnets must satisfy:
#   1. They must really exist, in the VPC you named.
#   2. They must be in TWO DIFFERENT Availability Zones (RDS demands this).
#   3. They should be PRIVATE (no route to an internet gateway) — best practice
#      for both the database and the EKS nodes.
#   4. They need spare IP addresses.
#
# Usage:
#   ./00b-find-subnets.sh            # list every subnet in $VPC_ID
#   ./00b-find-subnets.sh check      # validate the two in 00-env.sh
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-env.sh"

# --- Sanity check 0: is VPC_ID itself still a placeholder? -------------------
if [[ "$VPC_ID" == "vpc-0123456789abcdef0" ]]; then
  echo "STOP: VPC_ID in 00-env.sh is still the example value."
  echo "Your real VPCs in $AWS_REGION:"
  aws ec2 describe-vpcs --region "$AWS_REGION" \
    --query 'Vpcs[].{VPC:VpcId,CIDR:CidrBlock,Default:IsDefault,Name:Tags[?Key==`Name`]|[0].Value}' \
    --output table
  exit 1
fi

# --- Helper: is a subnet public (routes 0.0.0.0/0 to an internet gateway)? ---
is_public() {
  local subnet_id="$1"
  # Find the route table associated with this subnet; fall back to the VPC's main table.
  local rtb
  rtb=$(aws ec2 describe-route-tables --region "$AWS_REGION" \
    --filters "Name=association.subnet-id,Values=$subnet_id" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
  if [[ "$rtb" == "None" || -z "$rtb" ]]; then
    rtb=$(aws ec2 describe-route-tables --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
      --query 'RouteTables[0].RouteTableId' --output text)
  fi
  local igw
  igw=$(aws ec2 describe-route-tables --region "$AWS_REGION" --route-table-ids "$rtb" \
    --query "RouteTables[0].Routes[?GatewayId!=null && starts_with(GatewayId,'igw-')].GatewayId" \
    --output text)
  [[ -n "$igw" && "$igw" != "None" ]] && echo "PUBLIC" || echo "private"
}

# ---------------------------------------------------------------------------
if [[ "${1:-list}" == "list" ]]; then
  echo "==> Subnets in $VPC_ID ($AWS_REGION)"
  echo ""
  printf "%-26s %-14s %-20s %-8s %-9s %s\n" \
         "SUBNET ID" "AZ" "CIDR" "FREE-IPs" "TYPE" "NAME"
  printf "%-26s %-14s %-20s %-8s %-9s %s\n" \
         "--------------------------" "--------------" "--------------------" "--------" "---------" "----"

  aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[].[SubnetId,AvailabilityZone,CidrBlock,AvailableIpAddressCount,Tags[?Key==`Name`]|[0].Value]' \
    --output text | sort -k2 | while read -r id az cidr free name; do
      printf "%-26s %-14s %-20s %-8s %-9s %s\n" \
             "$id" "$az" "$cidr" "$free" "$(is_public "$id")" "${name:-—}"
  done

  cat <<'EOF'

--------------------------------------------------------------------------
WHAT TO DO NOW: pick TWO rows marked "private" that are in DIFFERENT AZs
(look at the AZ column — e.g. one us-east-1a and one us-east-1b).
Open scripts/00-env.sh and replace:

    export PRIVATE_SUBNET_1="subnet-aaaa1111"     <-- your first  real ID
    export PRIVATE_SUBNET_2="subnet-bbbb2222"     <-- your second real ID
    export VPC_CIDR="10.0.0.0/16"                 <-- your VPC's real CIDR

Then run:  ./00b-find-subnets.sh check
--------------------------------------------------------------------------
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
if [[ "$1" == "check" ]]; then
  echo "==> Validating the subnets currently set in 00-env.sh"
  FAILED=0

  for S in "$PRIVATE_SUBNET_1" "$PRIVATE_SUBNET_2"; do
    if ! aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$S" \
         --query 'Subnets[0].SubnetId' --output text >/dev/null 2>&1; then
      echo "  FAIL: $S does not exist in $AWS_REGION (this causes your error)."
      FAILED=1
      continue
    fi
    read -r AZ VPC FREE < <(aws ec2 describe-subnets --region "$AWS_REGION" \
      --subnet-ids "$S" \
      --query 'Subnets[0].[AvailabilityZone,VpcId,AvailableIpAddressCount]' --output text)
    echo "  OK  : $S  AZ=$AZ  vpc=$VPC  free-ips=$FREE  type=$(is_public "$S")"
    [[ "$VPC" != "$VPC_ID" ]] && { echo "        ^ WRONG VPC (expected $VPC_ID)"; FAILED=1; }
    [[ "$FREE" -lt 8 ]] && { echo "        ^ very few free IPs"; FAILED=1; }
  done
  [[ $FAILED -eq 1 ]] && exit 1

  AZ1=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$PRIVATE_SUBNET_1" \
        --query 'Subnets[0].AvailabilityZone' --output text)
  AZ2=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$PRIVATE_SUBNET_2" \
        --query 'Subnets[0].AvailabilityZone' --output text)
  if [[ "$AZ1" == "$AZ2" ]]; then
    echo "  FAIL: both subnets are in $AZ1. RDS requires TWO DIFFERENT AZs."
    exit 1
  fi
  echo "  OK  : two different AZs ($AZ1, $AZ2)"

  # The real VPC CIDR — used to open the DB firewall to VPC traffic only.
  REAL_CIDR=$(aws ec2 describe-vpcs --region "$AWS_REGION" --vpc-ids "$VPC_ID" \
              --query 'Vpcs[0].CidrBlock' --output text)
  echo "  Note: your VPC CIDR is $REAL_CIDR (VPC_CIDR in 00-env.sh is $VPC_CIDR)"
  [[ "$REAL_CIDR" != "$VPC_CIDR" ]] && echo "        ^ update VPC_CIDR to match."

  echo ""
  echo "ALL GOOD — you can now run ./01-rds-postgres.sh"
fi
