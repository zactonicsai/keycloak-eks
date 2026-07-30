#!/usr/bin/env bash
# =============================================================================
# 05-install-keycloak.sh — The grand finale: install Keycloak on the cluster.
#   1. Make the namespace and the two Secrets (DB password, admin password)
#   2. Fill in keycloak-values.yaml (online vs offline image locations)
#   3. helm install
#   4. Show you how to log in
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-env.sh"

echo "==> 1/4 Namespace + Secrets"
kubectl create namespace "$KC_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Passwords live in Secrets, never in YAML files checked into git. (Best practice.)
kubectl -n "$KC_NAMESPACE" create secret generic keycloak-db \
  --from-literal=password="$DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$KC_NAMESPACE" create secret generic keycloak-admin \
  --from-literal=password="$KC_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> 2/4 Looking up the RDS endpoint + choosing image sources"
export RDS_ENDPOINT=$(aws rds describe-db-instances --region "$AWS_REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
echo "    RDS endpoint: $RDS_ENDPOINT"

if [ "$OFFLINE" = "true" ]; then
  export KC_IMAGE_REPO="${ARTIFACTORY_HOST}/${ARTIFACTORY_DOCKER_REPO}/keycloak/keycloak"
  export BUSYBOX_REPO="${ARTIFACTORY_HOST}/${ARTIFACTORY_DOCKER_REPO}/library/busybox"
  export IMAGE_PULL_SECRETS='[{"name":"artifactory-pull"}]'
  CHART="internal/keycloakx"     # the repo added by 04-offline-mirror.sh upload
else
  export KC_IMAGE_REPO="quay.io/keycloak/keycloak"
  export BUSYBOX_REPO="docker.io/busybox"
  export IMAGE_PULL_SECRETS='[]'
  helm repo add codecentric https://codecentric.github.io/helm-charts 2>/dev/null || true
  helm repo update
  CHART="codecentric/keycloakx"
fi

# Fill ${...} placeholders in the values file with the variables above.
envsubst < "$(dirname "$0")/../keycloak-values.yaml" > /tmp/keycloak-values.rendered.yaml

echo "==> 3/4 helm install (Auto Mode will spin up a node for the pod — ~3-5 min)"
helm upgrade --install keycloak "$CHART" \
  --namespace "$KC_NAMESPACE" \
  --values /tmp/keycloak-values.rendered.yaml \
  --wait --timeout 15m

echo "==> 4/4 Status"
kubectl -n "$KC_NAMESPACE" get pods,svc
cat <<EOF

DONE! To open Keycloak from your laptop (free, no load balancer):

  kubectl -n $KC_NAMESPACE port-forward svc/keycloak-keycloakx-http 8080:80
  → browse http://localhost:8080
  → login: admin / (your KC_ADMIN_PASSWORD from 00-env.sh)

First task in the UI: create a permanent admin user, then delete the
temporary 'admin' bootstrap account (Keycloak reminds you to).
EOF
