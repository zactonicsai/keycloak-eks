# Keycloak on AWS EKS Auto Mode — The Complete Beginner-Friendly Tutorial

**What you will build:** Keycloak (a login/single-sign-on server) running inside a small
Kubernetes cluster on AWS (EKS Auto Mode, 1–2 nodes), talking to a PostgreSQL database
that lives **outside** the cluster in Amazon RDS. Everything can also be installed
**offline** (no internet) using your company's internal Artifactory server.

---

## 0. Background — What are all these things? (Middle-school explanations)

| Thing | What it really is |
|---|---|
| **Keycloak** | A program that handles logins for your other apps. Instead of every app having its own username/password system, they all ask Keycloak "is this person allowed in?" Like one security guard for a whole mall instead of one per store. |
| **Kubernetes (K8s)** | A "manager" for programs in containers. You tell it "keep 1 copy of Keycloak running," and it makes sure that happens, restarting it if it crashes. |
| **EKS** | Amazon's hosted Kubernetes. AWS runs the "brain" (control plane) for you. |
| **EKS Auto Mode** | EKS where AWS *also* manages the worker computers (nodes). Nodes appear when pods need them and disappear when they don't. You never patch or SSH into them — AWS does it. |
| **Node** | A virtual computer (EC2 instance) where your containers actually run. |
| **Pod** | The smallest unit Kubernetes runs — one or more containers wrapped together. Keycloak will run as one pod. |
| **RDS PostgreSQL** | Amazon's managed Postgres database. Keycloak stores users, passwords (hashed), and settings here. It lives **outside** the cluster so your data survives even if you delete the whole cluster. |
| **Subnet** | A "neighborhood" of IP addresses inside your VPC (your private network in AWS). **Private subnet** = no direct internet access (good for databases and nodes). |
| **IAM Role** | A badge that lets an AWS service do things. The cluster gets a badge, the nodes get a badge. |
| **SSM (Systems Manager)** | AWS's remote-control tool for servers — lets admins run commands on instances without SSH keys. |
| **Helm** | An "app store installer" for Kubernetes. A **chart** is the install package; a **values file** is your custom settings. |
| **Artifactory** | Your company's internal warehouse for software packages — Docker images, Helm charts, binaries. In an offline setup, everything is downloaded once on an internet machine, then uploaded here. |

### The picture

```
Your laptop ──(aws cli / kubectl / helm)──► AWS

VPC (already exists)
├── Private subnets (at least 2, in different Availability Zones)
│     ├── EKS Auto Mode nodes (1–2 EC2 machines) ── runs Keycloak pod
│     └── RDS PostgreSQL (OUTSIDE the cluster)  ◄── Keycloak connects on port 5432
└── Artifactory (internal) ── nodes pull the Keycloak image from here (offline mode)
```

### Why RDS outside the cluster? (Best practice)

* **Pro:** Your data is safe even if the cluster is destroyed; AWS handles backups, patching, and failover; databases hate being moved between nodes.
* **Con:** Costs money separately (~$12+/month) and is one more thing to set up.
* Running Postgres *inside* Kubernetes is fine for toy demos, but for anything real, external RDS is the standard best practice — and it's what we do here.

---

## 1. Order of operations (the info you need, in the order you need it)

1. **Gather offline files** (only if air-gapped) → Section 2
2. **Environment variables** → `scripts/00-env.sh`
3. **RDS PostgreSQL + DB subnet group + security group** → `scripts/01-rds-postgres.sh`
4. **IAM roles (cluster role + node role with SSM)** → `scripts/02-iam-roles.sh`
5. **EKS Auto Mode cluster, min 1 / max ~2 nodes** → `scripts/03-eks-cluster.sh` + `nodepool.yaml`
6. **Offline mirroring to Artifactory** → `scripts/04-offline-mirror.sh`
7. **Install Keycloak with Helm** → `scripts/05-install-keycloak.sh` + `keycloak-values.yaml`

Each script is safe to read top-to-bottom — that *is* the step-by-step.

---

## 2. Offline / air-gapped: every file you need and where to download it

Do this on a machine **with** internet, then carry the files (USB drive, DataSync,
whatever your security team allows) to the offline network and upload to Artifactory.

### 2.1 Tool binaries (installed on your admin workstation)

| File | Where to download | Purpose |
|---|---|---|
| `awscli-exe-linux-x86_64.zip` | `https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip` | AWS CLI v2 |
| `kubectl` (match your cluster version, e.g. 1.31) | `https://dl.k8s.io/release/v1.31.x/bin/linux/amd64/kubectl` | Talk to the cluster |
| `helm-v3.x.x-linux-amd64.tar.gz` | `https://get.helm.sh/` | Install charts |
| *(optional)* `eksctl_Linux_amd64.tar.gz` | `https://github.com/eksctl-io/eksctl/releases` | Easier cluster creation |

### 2.2 Docker images (uploaded to Artifactory Docker repo)

| Image | Where to pull | Why |
|---|---|---|
| `quay.io/keycloak/keycloak:26.6.1` | quay.io (check keycloak.org/downloads for the newest 26.x) | Keycloak itself — the **official** image, multi-arch (works on cheap ARM/Graviton nodes) |
| `docker.io/library/busybox:1.36` | Docker Hub | Tiny helper image the chart uses to wait for the database |

Save each as a tar file so it travels well: `docker save quay.io/keycloak/keycloak:26.6.1 -o keycloak-26.6.1.tar`

### 2.3 Helm chart (uploaded to Artifactory Helm repo)

| File | Where to get it | Why |
|---|---|---|
| `keycloakx-<version>.tgz` | `helm repo add codecentric https://codecentric.github.io/helm-charts` then `helm pull codecentric/keycloakx` | The chart that installs Keycloak. We use **codecentric/keycloakx** because it deploys the *official* Keycloak image (easy to mirror). The Bitnami chart now requires Bitnami's paid "Secure Images" for production use, which complicates offline mirroring. |

`scripts/04-offline-mirror.sh` automates the pull → retag → push to Artifactory.

**Why an internal registry at all?** Offline nodes can't reach quay.io. So we teach the
Helm values file to say "get the image from `artifactory.mycompany.com` instead," and we
give Kubernetes a password (an `imagePullSecret`) for it.

---

## 3. Step 1 — RDS PostgreSQL and the subnets it needs

Run: `bash scripts/01-rds-postgres.sh` (after editing `scripts/00-env.sh`)

**What it does, in plain words:**

1. **DB subnet group** — RDS demands a list of **at least 2 subnets in 2 different
   Availability Zones** (different physical buildings). Even a single-AZ database needs
   this list, so it knows where it *could* move in an emergency. Your VPC already
   exists, so you just hand RDS two of its **private** subnet IDs.
2. **Security group** — a firewall around the database. We open exactly **one door:
   TCP port 5432** (Postgres's port), and only to traffic coming from inside your VPC.
   Nothing on the internet can even see this database (`--no-publicly-accessible`).
3. **The database itself** — `db.t4g.micro` (the cheapest class, ARM-based), 20 GB of
   `gp3` storage, Single-AZ, Postgres 16.

**Cost choices explained:**
* `db.t4g.micro` ≈ $12/month — smallest that runs Keycloak comfortably for small teams. Bump to `db.t4g.small` if you have hundreds of active users.
* **Single-AZ** (no `--multi-az`) halves the price. Multi-AZ = a hot spare in another building; turn it on later for production with one command.
* `gp3` storage is cheaper and faster than the old `gp2`.
* You can **stop** an RDS instance for up to 7 days at a time when not using it.

---

## 4. Step 2 — IAM roles (with SSM)

Run: `bash scripts/02-iam-roles.sh`

Two badges get made:

1. **Cluster role** (`keycloak-eks-cluster-role`) — worn by the EKS control plane.
   Trusts `eks.amazonaws.com` (and must allow `sts:TagSession` — Auto Mode requires it).
   Gets these AWS-managed policies: `AmazonEKSClusterPolicy`, `AmazonEKSComputePolicy`,
   `AmazonEKSBlockStoragePolicy`, `AmazonEKSLoadBalancingPolicy`,
   `AmazonEKSNetworkingPolicy`. These let Auto Mode create/destroy nodes, disks, and
   load balancers on your behalf.
2. **Node role** (`keycloak-eks-node-role`) — worn by every EC2 node. Trusts
   `ec2.amazonaws.com`. Gets `AmazonEKSWorkerNodeMinimalPolicy`,
   `AmazonEC2ContainerRegistryPullOnly`, and — as you asked —
   **`AmazonSSMManagedInstanceCore`**, which is the policy that allows SSM
   (Session Manager / Run Command) on the instances.

> **Honest note about SSM on Auto Mode:** Auto Mode nodes are locked-down Bottlerocket
> machines that AWS manages. The SSM policy is attached (so the permission side is
> ready), but AWS discourages/blocks interactive logins to Auto Mode nodes — the
> supported way to poke at a node is `kubectl debug node/<name>`. If you truly need
> classic SSM sessions, standard (non-Auto) managed node groups allow it fully.
> Pro of Auto Mode: no patching, ever. Con: less low-level access.

---

## 5. Step 3 — The EKS Auto Mode cluster (min 1 node, max ~2)

Run: `bash scripts/03-eks-cluster.sh`

**What happens:**

1. `aws eks create-cluster` with `--compute-config enabled=true` = **Auto Mode on**.
   Auto Mode requires compute + block storage + load balancing all enabled together, so
   the script sets all three. It uses your existing VPC's private subnets.
2. Waits ~10 minutes (`aws eks wait cluster-active`), then sets up `kubectl`.
3. Applies **`nodepool.yaml`** — this is how we enforce your **"max 2 nodes"** rule.

**How "min 1 / max 2 nodes" really works in Auto Mode (important!):**
Auto Mode doesn't have a "max node count" knob. It uses **NodePools** (Karpenter under
the hood) that cap total **CPU and memory**. So we do the equivalent:

* We restrict instance sizes to small 2-vCPU machines (`c`,`m`,`r` families, ARM allowed for cheapness).
* We cap the pool at **`limits: cpu: 4`** → 4 vCPU ÷ 2 vCPU per machine = **at most 2 nodes**. Simple math, same result.
* "Min 1" happens naturally: as long as the Keycloak pod exists, Auto Mode keeps ≥1 node alive. (Scale Keycloak to 0 and Auto Mode may scale nodes to 0 — which saves money!)

**Pros/cons of Auto Mode:** Pro — zero node management, automatic right-sizing,
scale-to-zero. Con — small management fee (~12%) on top of EC2 price, and less control
of the boxes. For a 1–2 node cluster the fee is pennies vs. your time.

---

## 6. Step 4 — Mirror everything into Artifactory (offline networks)

Run on the internet machine + offline machine: `bash scripts/04-offline-mirror.sh`

It does the classic three-step for each image: **pull → retag → push**:

```
quay.io/keycloak/keycloak:26.6.1  →  artifactory.mycompany.com/docker-local/keycloak/keycloak:26.6.1
```

And for the chart: `helm pull` → `curl -T` upload to your Artifactory Helm repo →
on the offline side, `helm repo add internal https://artifactory.../api/helm/helm-local`.

Finally it creates the Kubernetes `imagePullSecret` so nodes can log in to Artifactory.

---

## 7. Step 5 — Install Keycloak with Helm

Run: `bash scripts/05-install-keycloak.sh`

**What the values file (`keycloak-values.yaml`) tells the chart, in plain words:**

* "Run **1 replica** of the official Keycloak image" (from Artifactory if offline).
* "Start in **production mode** (`start`), not dev mode."
* "**Don't** install a database in the cluster — connect to my RDS instead":
  `KC_DB=postgres`, `KC_DB_URL=jdbc:postgresql://<rds-endpoint>:5432/keycloak`,
  username/password read from a Kubernetes **Secret** (never hard-coded in YAML — best practice).
* "The first admin login is `admin` + a password from a Secret"
  (Keycloak 26 calls this the *bootstrap admin*).
* Small CPU/memory requests so it fits on one small node.

**Getting to the login page (cheapest first):**

1. **Free:** `kubectl port-forward svc/keycloak-keycloakx-http 8080:80` then open
   `http://localhost:8080` on your laptop. Perfect for setup/testing. $0.
2. **Later, for real users:** add an Ingress/NLB (Auto Mode can create one), which
   costs ~$16+/month — the values file has a commented-out ingress block ready.

---

## 8. Cost cheat-sheet (most cost-effective setup)

| Item | Choice | ~Monthly |
|---|---|---|
| EKS control plane | fixed price | ~$73 |
| Node (1× small ARM, e.g. c7g/m7g 2 vCPU spot-eligible) | Auto Mode picks cheapest that fits | ~$25–35 + ~12% Auto fee |
| RDS | db.t4g.micro, Single-AZ, gp3 20 GB | ~$14 |
| Load balancer | **skip it**, use port-forward while testing | $0 |
| **Total (test setup)** | | **~$115** |

Biggest levers: the control plane fee is the floor (fixed); scale Keycloak to 0 replicas overnight → nodes disappear; stop RDS on weekends; use ARM (Graviton) everywhere — Keycloak's official image supports it.

---

## 9. File map

```
keycloak-eks/
├── TUTORIAL.md                  ← you are here
├── keycloak-values.yaml         ← Helm settings (edit registry + hostname)
├── nodepool.yaml                ← the "max 2 nodes" enforcer
└── scripts/
    ├── 00-env.sh                ← EDIT THIS FIRST (your VPC, subnets, passwords)
    ├── 01-rds-postgres.sh       ← subnets group + firewall + database
    ├── 02-iam-roles.sh          ← cluster role + node role (SSM included)
    ├── 03-eks-cluster.sh        ← Auto Mode cluster + node limits
    ├── 04-offline-mirror.sh     ← internet → Artifactory → offline
    └── 05-install-keycloak.sh   ← the grand finale
```

## 10. Verify it worked

```bash
kubectl get nodes                     # 1 node appears (Auto Mode made it for you)
kubectl get pods                      # keycloak-keycloakx-0 → Running 1/1
kubectl logs sts/keycloak-keycloakx | grep started   # "Keycloak 26.x started"
kubectl port-forward svc/keycloak-keycloakx-http 8080:80
# browse http://localhost:8080 → log in with admin + your bootstrap password
```

First thing to do in the UI: create a **new permanent admin user**, then delete the
temporary bootstrap admin — Keycloak itself nags you to do this, and it's best practice.
