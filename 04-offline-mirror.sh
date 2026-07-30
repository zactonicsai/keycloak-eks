#!/usr/bin/env bash
# =============================================================================
# 04-offline-mirror.sh — Move everything Keycloak needs into your internal
# Artifactory so the offline cluster never touches the internet.
#
# Run PART A on a machine WITH internet.
# Carry the ./offline-bundle folder to the offline network (USB, etc.).
# Run PART B on a machine that can reach Artifactory.
# Run PART C from the machine that has kubectl access to the cluster.
#
# Usage:  ./04-offline-mirror.sh download | upload | secret
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-env.sh"

BUNDLE_DIR="./offline-bundle"
KC_IMAGE_SRC="quay.io/keycloak/keycloak:${KC_VERSION}"
BB_IMAGE_SRC="docker.io/library/busybox:1.36"
KC_IMAGE_DST="${ARTIFACTORY_HOST}/${ARTIFACTORY_DOCKER_REPO}/keycloak/keycloak:${KC_VERSION}"
BB_IMAGE_DST="${ARTIFACTORY_HOST}/${ARTIFACTORY_DOCKER_REPO}/library/busybox:1.36"

case "${1:-}" in

# ---------------------------------------------------------------------------
download)  # PART A — internet machine
  mkdir -p "$BUNDLE_DIR"
  echo "==> Pulling Docker images"
  docker pull "$KC_IMAGE_SRC"
  docker pull "$BB_IMAGE_SRC"
  echo "==> Saving images as portable .tar files"
  docker save "$KC_IMAGE_SRC" -o "$BUNDLE_DIR/keycloak-${KC_VERSION}.tar"
  docker save "$BB_IMAGE_SRC" -o "$BUNDLE_DIR/busybox-1.36.tar"
  echo "==> Pulling the Helm chart (.tgz)"
  helm repo add codecentric https://codecentric.github.io/helm-charts
  helm repo update
  helm pull codecentric/keycloakx --destination "$BUNDLE_DIR"
  echo "==> Also grab tool binaries into the bundle (edit versions as needed):"
  echo "    curl -LO https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
  echo "    curl -LO https://dl.k8s.io/release/v${K8S_VERSION}.0/bin/linux/amd64/kubectl"
  echo "    curl -LO https://get.helm.sh/helm-v3.16.4-linux-amd64.tar.gz"
  ls -lh "$BUNDLE_DIR"
  echo "DONE. Carry '$BUNDLE_DIR' to the offline network."
  ;;

# ---------------------------------------------------------------------------
upload)  # PART B — offline machine that can reach Artifactory
  echo "==> Logging in to Artifactory Docker registry"
  docker login "$ARTIFACTORY_HOST" -u "$ARTIFACTORY_USER" -p "$ARTIFACTORY_PASSWORD"

  echo "==> Loading images from tar, re-tagging, pushing"
  docker load -i "$BUNDLE_DIR/keycloak-${KC_VERSION}.tar"
  docker load -i "$BUNDLE_DIR/busybox-1.36.tar"
  docker tag "$KC_IMAGE_SRC" "$KC_IMAGE_DST" && docker push "$KC_IMAGE_DST"
  docker tag "$BB_IMAGE_SRC" "$BB_IMAGE_DST" && docker push "$BB_IMAGE_DST"

  echo "==> Uploading Helm chart to Artifactory Helm repo"
  CHART_TGZ=$(ls "$BUNDLE_DIR"/keycloakx-*.tgz | head -1)
  curl -u "$ARTIFACTORY_USER:$ARTIFACTORY_PASSWORD" \
       -T "$CHART_TGZ" \
       "https://${ARTIFACTORY_HOST}/artifactory/${ARTIFACTORY_HELM_REPO}/$(basename "$CHART_TGZ")"

  echo "==> Registering the internal Helm repo on this machine"
  helm repo add internal \
    "https://${ARTIFACTORY_HOST}/artifactory/api/helm/${ARTIFACTORY_HELM_REPO}" \
    --username "$ARTIFACTORY_USER" --password "$ARTIFACTORY_PASSWORD"
  helm repo update
  helm search repo internal/keycloakx
  echo "DONE. Chart + images now live in Artifactory."
  ;;

# ---------------------------------------------------------------------------
secret)  # PART C — give Kubernetes the Artifactory password (imagePullSecret)
  kubectl create namespace "$KC_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$KC_NAMESPACE" create secret docker-registry artifactory-pull \
    --docker-server="$ARTIFACTORY_HOST" \
    --docker-username="$ARTIFACTORY_USER" \
    --docker-password="$ARTIFACTORY_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "DONE. Nodes can now pull images from Artifactory."
  ;;

*)
  echo "Usage: $0 {download|upload|secret}"; exit 1 ;;
esac
