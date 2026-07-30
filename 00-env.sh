#!/usr/bin/env bash
# =============================================================================
# 00-env.sh — EDIT THIS FILE FIRST. Every other script "sources" it.
# Middle-school version: this is the one sheet of paper where you write down
# all your names, IDs and passwords, so the other scripts can read them.
# Usage in other scripts:  source "$(dirname "$0")/00-env.sh"
# =============================================================================

# ---- AWS basics -------------------------------------------------------------
export AWS_REGION="us-east-1"                 # your region
export CLUSTER_NAME="keycloak"
export K8S_VERSION="1.31"                     # check: aws eks describe-addon-versions

# ---- Your EXISTING VPC and its PRIVATE subnets ------------------------------
# The VPC already exists (per your note). Find subnets with:
#   aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
#     --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}' --output table
export VPC_ID="vpc-0123456789abcdef0"
export PRIVATE_SUBNET_1="subnet-aaaa1111"     # AZ 1 (e.g. us-east-1a)
export PRIVATE_SUBNET_2="subnet-bbbb2222"     # AZ 2 (e.g. us-east-1b)  <-- MUST be a different AZ
export VPC_CIDR="10.0.0.0/16"                 # used to open the DB firewall to the VPC only

# ---- RDS (lives OUTSIDE the EKS cluster) ------------------------------------
export DB_INSTANCE_ID="keycloak-db"
export DB_NAME="keycloak"
export DB_USERNAME="keycloak"
export DB_PASSWORD="CHANGE-ME-Str0ng-Pass!"   # 8-128 chars, no / @ " or spaces
export DB_INSTANCE_CLASS="db.t4g.micro"       # cheapest; db.t4g.small for more users
export DB_ENGINE_VERSION="16"                 # major version; RDS picks latest minor
export DB_STORAGE_GB="20"

# ---- Keycloak ---------------------------------------------------------------
export KC_VERSION="26.6.1"                    # verify newest 26.x at keycloak.org/downloads
export KC_ADMIN_PASSWORD="CHANGE-ME-Adm1n-Pass!"
export KC_NAMESPACE="keycloak"

# ---- Offline / Artifactory (leave alone if you have internet) ---------------
export OFFLINE="false"                        # "true" = pull from Artifactory
export ARTIFACTORY_HOST="artifactory.mycompany.com"
export ARTIFACTORY_DOCKER_REPO="docker-local"           # Docker repository key
export ARTIFACTORY_HELM_REPO="helm-local"               # Helm repository key
export ARTIFACTORY_USER="deploy-user"
export ARTIFACTORY_PASSWORD="CHANGE-ME"                 # or an API key/token

# ---- Derived (don't edit) ---------------------------------------------------
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '')"
