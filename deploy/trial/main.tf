# Conveyor trial on AWS: Conveyor behind an NLB with TLS, RDS PostgreSQL, S3 blobs,
# a self-hosted NativeLink (remote cache + remote execution) with a private CA, and an
# ECS Fargate cluster whose tasks clone open-source Bazel projects and stream builds in.
#
#   terraform init && terraform apply
#   terraform apply -var rbe_enabled=false -var nl_workers=0      # tear down NativeLink, keep Conveyor
#   terraform destroy                                             # everything
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
  backend "s3" {
    bucket       = "conveyor-trial-tfstate-948761147826"
    key          = "trial/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { project = "conveyor-trial", managed_by = "terraform" }
  }
}

variable "name" { default = "conveyor-trial" }
variable "region" { default = "us-east-1" }
variable "zone_id" { default = "Z06791603TH4X64U8OT9E" }
variable "conveyor_host" { default = "conveyor.algobien.com" }
variable "rbe_host" { default = "rbe.algobien.com" }
variable "cache_host" { default = "cache.rbe.algobien.com" }
variable "conveyor_image_tag" { default = "trial" }
variable "conveyor_instance_type" { default = "t4g.medium" }
variable "conveyor_count" { default = 1 }
variable "edge" {
  description = "How clients reach Conveyor: \"nlb\" (TLS at a Network Load Balancer with an ACM certificate, any node count) or \"caddy\" (one node with a Caddy sidecar: Let's Encrypt on 443 and h2 on 1985, an Elastic IP, no balancer)."
  default     = "caddy"
  validation {
    condition     = contains(["nlb", "caddy"], var.edge)
    error_message = "edge must be nlb or caddy"
  }
}
variable "db_snapshot_identifier" {
  description = "Build the database from this RDS snapshot instead of empty (a fresh stack restored from a backup). Changing it on an existing stack replaces the database."
  default     = null
}
variable "db_instance_class" { default = "db.t3.micro" }
variable "rbe_enabled" { default = false }
variable "nl_control_type" { default = "c6i.xlarge" }
variable "nl_worker_type" { default = "c6i.2xlarge" }
variable "nl_workers" { default = 0 }
variable "nl_cas_gb" { default = 200 }
variable "allow_cidrs" {
  description = "Extra CIDRs allowed to reach NativeLink's ports (a laptop, for example)."
  type        = list(string)
  default     = []
}
variable "drain_seconds" { default = 45 }

data "aws_caller_identity" "me" {}
data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}
data "aws_ssm_parameter" "al2023_x86" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  subnets = slice(sort(data.aws_subnets.default.ids), 0, 3)
  ecr     = "${data.aws_caller_identity.me.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

resource "random_password" "db" {
  length  = 32
  special = false
}
resource "random_password" "secret_key_base" {
  length  = 64
  special = false
}
resource "random_password" "release_cookie" {
  length  = 40
  special = false
}
resource "random_password" "admin_token" {
  length  = 32
  special = false
}
