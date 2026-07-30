#!/usr/bin/env bash
# =============================================================================
# 01-rds-postgres.sh — Create the PostgreSQL database OUTSIDE the cluster.
# Order of work:
#   1. DB SUBNET GROUP  (RDS needs >= 2 subnets in 2 different AZs — a rule)
#   2. SECURITY GROUP   (firewall: only port 5432, only from inside the VPC)
#   3. THE DATABASE     (cheapest sensible settings)
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-env.sh"

echo "==> 1/3 DB subnet group (the 'list of neighborhoods' RDS may live in)"
aws rds create-db-subnet-group \
  --region "$AWS_REGION" \
  --db-subnet-group-name keycloak-db-subnets \
  --db-subnet-group-description "Private subnets for Keycloak RDS" \
  --subnet-ids "$PRIVATE_SUBNET_1" "$PRIVATE_SUBNET_2"

echo "==> 2/3 Security group (firewall around the database)"
DB_SG_ID=$(aws ec2 create-security-group \
  --region "$AWS_REGION" \
  --group-name keycloak-db-sg \
  --description "Allow Postgres 5432 from inside the VPC only" \
  --vpc-id "$VPC_ID" \
  --query GroupId --output text)
echo "    Security group: $DB_SG_ID"

# Open exactly one door: TCP 5432, and only to callers inside your VPC.
# (The EKS nodes live in the VPC, so Keycloak can get in. The internet cannot.)
aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$DB_SG_ID" \
  --protocol tcp --port 5432 --cidr "$VPC_CIDR"

echo "==> 3/3 Creating the database (takes ~10 minutes)"
aws rds create-db-instance \
  --region "$AWS_REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --db-name "$DB_NAME" \
  --engine postgres \
  --engine-version "$DB_ENGINE_VERSION" \
  --db-instance-class "$DB_INSTANCE_CLASS" \
  --allocated-storage "$DB_STORAGE_GB" \
  --storage-type gp3 \
  --master-username "$DB_USERNAME" \
  --master-user-password "$DB_PASSWORD" \
  --db-subnet-group-name keycloak-db-subnets \
  --vpc-security-group-ids "$DB_SG_ID" \
  --no-publicly-accessible \
  --no-multi-az \
  --backup-retention-period 1 \
  --storage-encrypted \
  --tags Key=app,Value=keycloak
# Cost notes: t4g.micro + Single-AZ + gp3 = cheapest safe combo (~$14/mo).
# For production later: add --multi-az and raise --backup-retention-period.

echo "==> Waiting for the database to be ready..."
aws rds wait db-instance-available --region "$AWS_REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID"

RDS_ENDPOINT=$(aws rds describe-db-instances --region "$AWS_REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text)

echo ""
echo "DONE. Write this down — the Helm install needs it:"
echo "  RDS_ENDPOINT=$RDS_ENDPOINT"
echo "  JDBC URL   = jdbc:postgresql://$RDS_ENDPOINT:5432/$DB_NAME"
