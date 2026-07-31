# =============================================================================
# STACK 05 — Keycloak itself (namespace, secrets, Helm release)
#
# Depends on: stack 03 (cluster) and stack 01 (database endpoint + SSM path).
# Stack 04 should already be applied, or there will be no node to run the pod on.
#
# The database password is READ FROM SSM, never typed into a tfvars file.
# =============================================================================
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws        = { source = "hashicorp/aws", version = ">= 5.79" }
    kubernetes = { source = "hashicorp/kubernetes", version = ">= 2.32" }
    helm       = { source = "hashicorp/helm", version = ">= 2.15" }
    random     = { source = "hashicorp/random", version = ">= 3.6" }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

# The DB password stack 01 generated. with_decryption pulls the plaintext.
data "aws_ssm_parameter" "db_password" {
  name            = var.db_password_ssm_path
  with_decryption = true
}

locals {
  kube_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.aws_region]
  }

  # Offline: images and chart come from Artifactory. Online: from quay.io/Docker Hub.
  keycloak_image = var.offline_mode ? "${var.artifactory_host}/${var.artifactory_docker_repo}/keycloak/keycloak" : "quay.io/keycloak/keycloak"
  busybox_image  = var.offline_mode ? "${var.artifactory_host}/${var.artifactory_docker_repo}/library/busybox" : "docker.io/busybox"
  chart_repo     = var.offline_mode ? "https://${var.artifactory_host}/artifactory/api/helm/${var.artifactory_helm_repo}" : "https://codecentric.github.io/helm-charts"
  pull_secrets   = var.offline_mode ? [{ name = kubernetes_secret.artifactory[0].metadata[0].name }] : []
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  exec {
    api_version = local.kube_exec.api_version
    command     = local.kube_exec.command
    args        = local.kube_exec.args
  }
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    exec {
      api_version = local.kube_exec.api_version
      command     = local.kube_exec.command
      args        = local.kube_exec.args
    }
  }
}

# ---------------------------------------------------------------------------
resource "kubernetes_namespace" "this" {
  metadata {
    name   = var.namespace
    labels = { app = "keycloak" }
  }
}

# ---------------------------------------------------------------------------
# Secrets. Passwords live in Kubernetes Secrets, never inline in Helm values —
# values end up in the Helm release history, which is readable cluster-wide.
# ---------------------------------------------------------------------------
resource "kubernetes_secret" "db" {
  metadata {
    name      = "keycloak-db"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  data = {
    password = data.aws_ssm_parameter.db_password.value
  }
  type = "Opaque"
}

# The first admin login. Generated here and also written to SSM so you can read
# it later without digging through terraform state.
resource "random_password" "admin" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+"
}

resource "aws_ssm_parameter" "admin_password" {
  name      = var.admin_password_ssm_path
  type      = "SecureString"
  value     = random_password.admin.result
  overwrite = true
  tags      = var.tags
}

resource "kubernetes_secret" "admin" {
  metadata {
    name      = "keycloak-admin"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  data = {
    password = random_password.admin.result
  }
  type = "Opaque"
}

# Registry login, only needed when pulling from Artifactory.
resource "kubernetes_secret" "artifactory" {
  count = var.offline_mode ? 1 : 0

  metadata {
    name      = "artifactory-pull"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (var.artifactory_host) = {
          username = var.artifactory_username
          password = var.artifactory_password
          auth     = base64encode("${var.artifactory_username}:${var.artifactory_password}")
        }
      }
    })
  }
}

# ---------------------------------------------------------------------------
# The Helm release.
# Chart: codecentric/keycloakx — it deploys the OFFICIAL Keycloak image, which
# makes offline mirroring simple. (Bitnami's chart now points at images behind
# their paid Secure Images program, which complicates air-gapped setups.)
# ---------------------------------------------------------------------------
resource "helm_release" "keycloak" {
  name       = "keycloak"
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = local.chart_repo
  chart      = "keycloakx"
  version    = var.chart_version

  repository_username = var.offline_mode ? var.artifactory_username : null
  repository_password = var.offline_mode ? var.artifactory_password : null

  wait    = true
  timeout = 900 # Auto Mode must boot a node first, so allow 15 minutes

  values = [yamlencode({
    replicas = var.replicas

    image = {
      repository = local.keycloak_image
      tag        = var.keycloak_version
    }

    imagePullSecrets = local.pull_secrets

    command = [
      "/opt/keycloak/bin/kc.sh",
      "start",              # production mode; "start-dev" is never for real use
      "--http-enabled=true", # plain HTTP inside the cluster; TLS goes on the LB
      "--http-port=8080",
      "--hostname-strict=${var.hostname_strict}",
    ]

    extraEnv = yamlencode([
      {
        name = "KC_BOOTSTRAP_ADMIN_USERNAME" # Keycloak 26+ naming
        value = var.admin_username
      },
      {
        name = "KC_BOOTSTRAP_ADMIN_PASSWORD"
        valueFrom = {
          secretKeyRef = { name = kubernetes_secret.admin.metadata[0].name, key = "password" }
        }
      },
      {
        name  = "KC_PROXY_HEADERS" # trust X-Forwarded-* from the load balancer
        value = "xforwarded"
      },
      {
        name  = "JAVA_OPTS_APPEND"
        value = "-XX:MaxRAMPercentage=70"
      },
    ])

    # Points at the RDS instance from stack 01 — OUTSIDE the cluster.
    database = {
      vendor            = "postgres"
      hostname          = var.rds_endpoint
      port              = var.rds_port
      database          = var.db_name
      username          = var.db_username
      existingSecret    = kubernetes_secret.db.metadata[0].name
      existingSecretKey = "password"
    }

    # Waits until the database answers before Keycloak boots.
    dbchecker = {
      enabled = true
      image   = { repository = local.busybox_image, tag = "1.36" }
    }

    resources = {
      requests = { cpu = "250m", memory = "768Mi" }
      # No CPU limit on purpose — CPU limits throttle JVM startup badly.
      limits = { memory = var.memory_limit }
    }

    service = { type = "ClusterIP" } # free; use port-forward to reach it

    http = { relativePath = "/" }

    ingress = {
      enabled = var.ingress_enabled
      ingressClassName = "alb"
      annotations = {
        "alb.ingress.kubernetes.io/scheme"      = var.ingress_internal ? "internal" : "internet-facing"
        "alb.ingress.kubernetes.io/target-type" = "ip"
      }
      rules = var.ingress_enabled ? [{
        host  = var.ingress_hostname
        paths = [{ path = "/", pathType = "Prefix" }]
      }] : []
    }
  })]

  depends_on = [kubernetes_secret.db, kubernetes_secret.admin]
}
