# =============================================================================
# STACK 01 — RDS PostgreSQL (lives OUTSIDE the EKS cluster)
#
# Independent: depends on NOTHING except your pre-existing VPC.
# Run this first. Its outputs feed stack 05 (keycloak).
#
# Creates: DB subnet group, security group, random password in SSM, the DB.
# =============================================================================
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws    = { source = "hashicorp/aws", version = ">= 5.79" }
    random = { source = "hashicorp/random", version = ">= 3.6" }
  }
}

provider "aws" {
  region = var.aws_region
}

# The VPC already exists — we only READ it, never create or destroy it.
data "aws_vpc" "this" {
  id = var.vpc_id
}

# ---------------------------------------------------------------------------
# DB subnet group — RDS requires >= 2 subnets in >= 2 Availability Zones.
# Even a Single-AZ database needs the list, so it knows where it could move.
# ---------------------------------------------------------------------------
resource "aws_db_subnet_group" "this" {
  name        = "${var.name_prefix}-db-subnets"
  description = "Private subnets for Keycloak RDS"
  subnet_ids  = var.private_subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-db-subnets" })
}

# ---------------------------------------------------------------------------
# Security group — the firewall around the database.
# Exactly one door open: TCP 5432, only to traffic already inside the VPC.
# ---------------------------------------------------------------------------
resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db-sg"
  description = "Allow PostgreSQL 5432 from inside the VPC only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-db-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  security_group_id = aws_security_group.db.id
  description       = "PostgreSQL from within the VPC (EKS nodes live here)"
  cidr_ipv4         = coalesce(var.allowed_cidr, data.aws_vpc.this.cidr_block)
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
}

# ---------------------------------------------------------------------------
# Password — generated here, stored in SSM Parameter Store (free tier).
# Stack 05 reads it back from SSM, so the secret never travels in a tfvars file.
# RDS forbids / @ " and spaces in master passwords, hence override_special.
# ---------------------------------------------------------------------------
resource "random_password" "db" {
  length           = 28
  special          = true
  override_special = "!#$%&*()-_=+[]:?"
}

resource "aws_ssm_parameter" "db_password" {
  name        = var.db_password_ssm_path
  description = "Keycloak RDS master password"
  type        = "SecureString"
  value       = random_password.db.result

  tags = var.tags
}

# ---------------------------------------------------------------------------
# The database itself — cheapest sensible production-ish settings.
# ---------------------------------------------------------------------------
resource "aws_db_instance" "this" {
  identifier     = "${var.name_prefix}-db"
  engine         = "postgres"
  engine_version = var.engine_version # major only; RDS picks the latest minor

  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_type      = "gp3" # cheaper and faster than the old gp2
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false        # nothing on the internet can even see it
  multi_az               = var.multi_az # false = half the price

  backup_retention_period   = var.backup_retention_days
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name_prefix}-db-final"
  deletion_protection       = var.deletion_protection

  auto_minor_version_upgrade = true
  apply_immediately          = true

  # Quiet hours for maintenance/backups (UTC).
  backup_window      = "03:00-04:00"
  maintenance_window = "sun:04:30-sun:05:30"

  tags = merge(var.tags, { Name = "${var.name_prefix}-db" })
}
