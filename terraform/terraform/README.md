# Terraform — five independent stacks

Each folder is a **separate root module with its own state file**. You can run,
re-run, or destroy any one of them without touching the others. Nothing uses
`terraform_remote_state`; values move between stacks as ordinary variables, so
each stack works standalone if you write its `terraform.tfvars` by hand.

```
terraform/
├── common.env.example    ← the few values YOU supply
├── gen-tfvars.sh         ← writes each stack's tfvars from earlier outputs
├── backend.tf.example    ← optional S3 state (copy into each stack)
├── 01-rds/               depends on: nothing (just your VPC)
├── 02-iam/               depends on: nothing
├── 03-eks/               depends on: 02 (two role ARNs)
├── 04-nodepool/          depends on: 02 (role name), 03 (cluster + SG)
└── 05-keycloak/          depends on: 01 (database), 03 (cluster)
```

Stacks 01 and 02 have no dependencies at all, so they can run in parallel.

## Quick start

```bash
cd terraform
cp common.env.example common.env      # then edit: region, vpc, 2 subnets
./gen-tfvars.sh 01 && (cd 01-rds     && terraform init && terraform apply)
./gen-tfvars.sh 02 && (cd 02-iam     && terraform init && terraform apply)
./gen-tfvars.sh 03 && (cd 03-eks     && terraform init && terraform apply)
./gen-tfvars.sh 04 && (cd 04-nodepool && terraform init && terraform apply)
./gen-tfvars.sh 05 && (cd 05-keycloak && terraform init && terraform apply)
```

`gen-tfvars.sh 03` reads stack 02's outputs, `04` reads 02 and 03, `05` reads
01 and 03. Run it *after* the stack it depends on has been applied, or it will
tell you which one is missing.

## What each stack does

| Stack | Creates | Key outputs |
|---|---|---|
| **01-rds** | DB subnet group, security group (5432 from VPC only), generated password in SSM, PostgreSQL instance | `rds_endpoint`, `db_password_ssm_path` |
| **02-iam** | Cluster role (5 Auto Mode policies), node role (worker + ECR pull + **SSM**) | `cluster_role_arn`, `node_role_arn`, `node_role_name` |
| **03-eks** | EKS cluster with Auto Mode on, access entries | `cluster_name`, `cluster_security_group_id` |
| **04-nodepool** | Custom NodeClass + NodePool — **this is where max 2 nodes is enforced** | `cpu_limit` |
| **05-keycloak** | Namespace, secrets, Helm release pointed at the external RDS | `port_forward_command`, `admin_password_command` |

## How "min 1 / max 2 nodes" is enforced

Auto Mode has no node-count setting — Karpenter caps a pool by total CPU. So:

* Stack 03 sets `builtin_node_pools = []`, disabling AWS's uncapped default pool.
* Stack 04 permits only 2-vCPU instance types and sets `limits.cpu = 4`.
* 4 vCPU ÷ 2 vCPU per machine = **at most 2 nodes**.

Change `max_nodes` or `vcpu_per_node` in `common.env` and the limit recalculates.
Keep `vcpu_per_node` matching the instance sizes you allow, or the math breaks.

"Min 1" needs no setting: while the Keycloak pod exists, a node must exist to
hold it. Scale Keycloak to 0 replicas and nodes drop to 0 — a real way to save
money overnight.

## Secrets

No password is ever written into a tfvars file.

* Stack 01 generates the DB password and stores it in SSM Parameter Store.
* Stack 05 **reads it back from SSM** and puts it in a Kubernetes Secret.
* Stack 05 generates the Keycloak admin password and also writes it to SSM.

Read the admin password afterwards:

```bash
aws ssm get-parameter --name /keycloak/admin/password \
  --with-decryption --query Parameter.Value --output text
```

The one secret Terraform can't generate is your Artifactory password. Pass it
through the environment rather than a file:

```bash
export TF_VAR_artifactory_password="$(aws ssm get-parameter \
  --name /keycloak/artifactory/password --with-decryption \
  --query Parameter.Value --output text)"
```

Note that Terraform state contains secrets in plaintext regardless. If anyone
else can read your state, use the S3 backend with encryption (see
`backend.tf.example`) and lock down the bucket.

## Offline / air-gapped

Mirror the images and chart into Artifactory first — the shell script
`../scripts/04-offline-mirror.sh download|upload` still does that part. Then in
`common.env`:

```bash
OFFLINE_MODE="true"
ARTIFACTORY_HOST="artifactory.mycompany.com"
```

Stack 05 then pulls the chart from your Artifactory Helm repo, points the image
at your Docker repo, and creates the `imagePullSecret` automatically.

For a truly sealed network also set `endpoint_public_access = false` in stack
03 — but then `kubectl`, and therefore stacks 04 and 05, must run from inside
the VPC (a bastion, a VPN, or CI running in a private subnet).

## Reaching Keycloak

Default is `ingress_enabled = false`, which costs nothing:

```bash
kubectl -n keycloak port-forward svc/keycloak-keycloakx-http 8080:80
# http://localhost:8080
```

When real users need in, set `ingress_enabled = true` plus a real
`ingress_hostname`, and turn on `hostname_strict = true` at the same time. A
load balancer runs about $16/month.

## Destroying

Reverse order, because AWS won't delete something another thing still holds:

```bash
(cd 05-keycloak && terraform destroy)   # removes any load balancer first
(cd 04-nodepool && terraform destroy)
(cd 03-eks      && terraform destroy)
(cd 02-iam      && terraform destroy)
(cd 01-rds      && terraform destroy)   # LAST — this deletes your user data
```

Destroying 03–05 and keeping 01 is the money-saving move: the cluster is cheap
to rebuild, your realms and users are not. Leaving RDS running costs ~$14/month.

If a destroy half-fails, `../scripts/99-destroy.sh` cleans up leftovers with the
AWS CLI and is safe to run repeatedly.

## Known rough edges

* **`kubernetes_manifest` in stack 04** contacts the cluster API during `plan`,
  not just `apply`. So stack 04 cannot be planned before stack 03 exists, and a
  `plan` will fail if your kubeconfig or network can't reach the API. This is a
  known limitation of that resource type, not a mistake in the config.
* **Provider versions matter.** Auto Mode's `compute_config` block needs AWS
  provider 5.79 or newer. An older provider gives a confusing "unsupported
  block" error.
* **`terraform destroy` on stack 03 can hang** if load balancers created by
  Kubernetes still exist. Always destroy 05 first.
