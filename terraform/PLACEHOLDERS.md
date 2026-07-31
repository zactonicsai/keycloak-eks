# Placeholder Reference — the AWS CLI command behind every value

Run `./00c-discover.sh` to do all of this automatically. This page is the manual
version, so you can see (and trust) where each number comes from.

Set your region once so you can skip `--region` everywhere:

```bash
export AWS_REGION=us-east-1
```

---

## The identity check (do this first)

If your credentials are wrong, everything else fails with confusing errors.

```bash
aws sts get-caller-identity
```

`Account` from that output is your **ACCOUNT_ID**. Just the number:

```bash
aws sts get-caller-identity --query Account --output text
```

---

## VPC_ID

List them, then pick the one your team already uses. Default VPCs are all-public
and a poor fit here, so `IsDefault=false` is usually what you want.

```bash
aws ec2 describe-vpcs \
  --query 'Vpcs[].{VPC:VpcId,CIDR:CidrBlock,Default:IsDefault,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table
```

Search by name tag if your VPCs are labeled:

```bash
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*prod*" \
  --query 'Vpcs[].VpcId' --output text
```

## VPC_CIDR

The IP range of that VPC. `01-rds-postgres.sh` uses it to open the database
firewall to VPC traffic **only**.

```bash
aws ec2 describe-vpcs --vpc-ids vpc-YOURID \
  --query 'Vpcs[0].CidrBlock' --output text
```

If the VPC has extra ranges attached, list them all:

```bash
aws ec2 describe-vpcs --vpc-ids vpc-YOURID \
  --query 'Vpcs[0].CidrBlockAssociationSet[].CidrBlock' --output text
```

---

## PRIVATE_SUBNET_1 and PRIVATE_SUBNET_2

Two steps, because "is it private?" isn't a field on the subnet — it depends on
the subnet's route table.

**Step 1 — list all subnets with their AZ and spare IPs:**

```bash
aws ec2 describe-subnets --filters "Name=vpc-id,Values=vpc-YOURID" \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,FreeIPs:AvailableIpAddressCount,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table
```

**Step 2 — check whether a subnet routes to the internet.** If this prints an
`igw-…` id, the subnet is **public**; empty output means **private**:

```bash
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=subnet-YOURID" \
  --query "RouteTables[0].Routes[?starts_with(GatewayId||'','igw-')].GatewayId" \
  --output text
```

Many VPCs tag their subnets, which makes this a one-liner:

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=vpc-YOURID" "Name=tag:Name,Values=*private*" \
  --query 'Subnets[].[SubnetId,AvailabilityZone]' --output text
```

**The rule to satisfy:** two subnets, two *different* Availability Zones. Check
the AZ column — one `us-east-1a`, one `us-east-1b`. Same AZ twice is the error
RDS rejects.

Which AZs exist in your region:

```bash
aws ec2 describe-availability-zones \
  --query 'AvailabilityZones[].ZoneName' --output text
```

---

## K8S_VERSION

The newest Kubernetes version EKS currently offers. The reliable trick is to ask
which cluster versions a core addon supports:

```bash
aws eks describe-addon-versions --addon-name vpc-cni \
  --query 'addons[0].addonVersions[0].compatibilities[].clusterVersion' \
  --output text | tr '\t' '\n' | sort -V | tail -1
```

Newer CLI versions also have a direct command:

```bash
aws eks describe-cluster-versions --output table
```

## CLUSTER_NAME

Any name you like — just don't collide with an existing cluster:

```bash
aws eks list-clusters --output table
```

---

## DB_ENGINE_VERSION

Newest PostgreSQL major version available in your region:

```bash
aws rds describe-db-engine-versions --engine postgres \
  --query 'DBEngineVersions[].EngineVersion' --output text \
  | tr '\t' '\n' | sort -V | tail -5
```

Only the versions AWS considers current defaults:

```bash
aws rds describe-db-engine-versions --engine postgres --default-only \
  --query 'DBEngineVersions[].EngineVersion' --output text
```

## DB_INSTANCE_CLASS

Confirm the cheap ARM class exists in your region before relying on it. Empty
output means use `db.t3.micro` instead:

```bash
aws rds describe-orderable-db-instance-options \
  --engine postgres --db-instance-class db.t4g.micro \
  --query 'OrderableDBInstanceOptions[0].[DBInstanceClass,EngineVersion,MultiAZCapable]' \
  --output text
```

See every micro/small class available:

```bash
aws rds describe-orderable-db-instance-options --engine postgres \
  --query 'OrderableDBInstanceOptions[].DBInstanceClass' --output text \
  | tr '\t' '\n' | sort -u | grep -E 'micro|small'
```

## DB_INSTANCE_ID

Your choice; must be unique in the account and region:

```bash
aws rds describe-db-instances \
  --query 'DBInstances[].DBInstanceIdentifier' --output text
```

## RDS_ENDPOINT (after creation)

You don't set this — it's produced by step 1 and read automatically by step 5:

```bash
aws rds describe-db-instances --db-instance-identifier keycloak-db \
  --query 'DBInstances[0].Endpoint.Address' --output text
```

---

## DB_PASSWORD and KC_ADMIN_PASSWORD

Let AWS generate them. RDS master passwords may not contain `/`, `@`, `"`, or
spaces, hence the exclusions:

```bash
aws secretsmanager get-random-password \
  --password-length 28 --require-each-included-type \
  --exclude-characters '/@" ' \
  --query RandomPassword --output text
```

**Better than a file (best practice):** store them in SSM Parameter Store, which
is free for standard parameters, and read them at runtime.

```bash
# Store once
aws ssm put-parameter --name /keycloak/db/password --type SecureString \
  --value "$(aws secretsmanager get-random-password --password-length 28 \
             --require-each-included-type --exclude-characters '/@" ' \
             --query RandomPassword --output text)"

# Read whenever a script needs it
export DB_PASSWORD=$(aws ssm get-parameter --name /keycloak/db/password \
  --with-decryption --query Parameter.Value --output text)
```

Swap those two `export` lines into `00-env.sh` and no password ever touches disk.

---

## IAM role ARNs

You don't set these by hand — the scripts create the roles and look up the ARNs.
To check for name collisions before running step 2:

```bash
aws iam get-role --role-name keycloak-eks-cluster-role
aws iam get-role --role-name keycloak-eks-node-role
```

"NoSuchEntity" is the *good* answer — it means the name is free.

Confirm the SSM policy landed on the node role after step 2:

```bash
aws iam list-attached-role-policies --role-name keycloak-eks-node-role \
  --query 'AttachedPolicies[].PolicyName' --output text
```

---

## Values that are NOT from AWS

| Variable | Where it comes from |
|---|---|
| `KC_VERSION` | keycloak.org/downloads — pick the newest 26.x |
| `ARTIFACTORY_HOST` | your Artifactory admin / the URL you log into |
| `ARTIFACTORY_DOCKER_REPO`, `ARTIFACTORY_HELM_REPO` | the repository **keys** shown in Artifactory's Repositories screen |
| `ARTIFACTORY_USER`, `ARTIFACTORY_PASSWORD` | a service account your admin issues; store the password in SSM as shown above |
| `KC_NAMESPACE`, `DB_NAME`, `DB_USERNAME` | your choice — the defaults are fine |

---

## One-shot: print everything at once

```bash
export AWS_REGION=us-east-1
export VPC_ID=vpc-YOURID

echo "ACCOUNT_ID      = $(aws sts get-caller-identity --query Account --output text)"
echo "VPC_CIDR        = $(aws ec2 describe-vpcs --vpc-ids $VPC_ID --query 'Vpcs[0].CidrBlock' --output text)"
echo "K8S_VERSION     = $(aws eks describe-addon-versions --addon-name vpc-cni \
      --query 'addons[0].addonVersions[0].compatibilities[].clusterVersion' --output text \
      | tr '\t' '\n' | sort -V | tail -1)"
echo "PG_VERSION      = $(aws rds describe-db-engine-versions --engine postgres --default-only \
      --query 'DBEngineVersions[-1].EngineVersion' --output text)"
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,FreeIPs:AvailableIpAddressCount}' --output table
```
