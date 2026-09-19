terraform {
  required_providers { aws = { source = "hashicorp/aws", version = ">= 5.0" } }
}

variable "name" { default = "conveyor" }
variable "region" { default = "us-east-1" }
variable "vpc_id" {}
variable "subnet_ids" { type = list(string) }
variable "instance_type" { default = "c7g.xlarge" }
variable "image" { default = "ghcr.io/example/conveyor:0.1.0" }
variable "desired" { default = 3 }
variable "min" { default = 2 }
variable "max" { default = 12 }
variable "database_url" { sensitive = true }
variable "secret_key_base" { sensitive = true }
variable "release_cookie" { sensitive = true }
variable "admin_token" { sensitive = true, default = "" }
variable "phx_host" { default = "conveyor.example.com" }
variable "drain_seconds" { default = 45 }

provider "aws" { region = var.region }

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter { name = "name", values = ["al2023-ami-*-arm64"] }
}

resource "aws_s3_bucket" "blobs" { bucket = "${var.name}-blobs" }

resource "aws_iam_role" "node" {
  name = "${var.name}-node"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}

resource "aws_iam_role_policy" "node" {
  role = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ec2:DescribeInstances"], Resource = "*" },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "${aws_s3_bucket.blobs.arn}/*" },
      { Effect = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.blobs.arn },
    ]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.name}-node"
  role = aws_iam_role.node.name
}

resource "aws_security_group" "node" {
  name   = "${var.name}-node"
  vpc_id = var.vpc_id
  # gRPC and HTTP from the balancer; epmd + distribution between members.
  ingress { from_port = 1985, to_port = 1985, protocol = "tcp", security_groups = [aws_security_group.lb.id] }
  ingress { from_port = 4000, to_port = 4000, protocol = "tcp", security_groups = [aws_security_group.lb.id] }
  ingress { from_port = 4369, to_port = 4369, protocol = "tcp", self = true }
  ingress { from_port = 9100, to_port = 9100, protocol = "tcp", self = true }
  egress { from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "lb" {
  name   = "${var.name}-lb"
  vpc_id = var.vpc_id
  ingress { from_port = 1985, to_port = 1985, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 443, to_port = 443, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] }
  egress { from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_launch_template" "node" {
  name_prefix   = "${var.name}-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type
  iam_instance_profile { name = aws_iam_instance_profile.node.name }
  vpc_security_group_ids = [aws_security_group.node.id]
  metadata_options { http_tokens = "required" }
  user_data = base64encode(templatefile("${path.module}/user-data.sh.tftpl", {
    name            = var.name
    image           = var.image
    region          = var.region
    database_url    = var.database_url
    secret_key_base = var.secret_key_base
    release_cookie  = var.release_cookie
    admin_token     = var.admin_token
    phx_host        = var.phx_host
    bucket          = aws_s3_bucket.blobs.bucket
    drain_seconds   = var.drain_seconds
  }))
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = var.name, "conveyor-cluster" = var.name }
  }
}

resource "aws_lb" "nlb" {
  name               = var.name
  load_balancer_type = "network"
  subnets            = var.subnet_ids
  security_groups    = [aws_security_group.lb.id]
}

resource "aws_lb_target_group" "grpc" {
  name        = "${var.name}-grpc"
  port        = 1985
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  deregistration_delay = var.drain_seconds
  health_check { protocol = "HTTP", port = "4000", path = "/health/ready", interval = 10, healthy_threshold = 2, unhealthy_threshold = 2 }
}

resource "aws_lb_target_group" "web" {
  name        = "${var.name}-web"
  port        = 4000
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  health_check { protocol = "HTTP", port = "4000", path = "/health/ready", interval = 10 }
}

resource "aws_lb_listener" "grpc" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 1985
  protocol          = "TCP"
  default_action { type = "forward", target_group_arn = aws_lb_target_group.grpc.arn }
}

# Terminate TLS for the UI on the NLB (certificate_arn from ACM); gRPC TLS is passed through
# to the instances or terminated here with a TLS listener the same way.
resource "aws_lb_listener" "web" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 443
  protocol          = "TCP"
  default_action { type = "forward", target_group_arn = aws_lb_target_group.web.arn }
}

resource "aws_autoscaling_group" "nodes" {
  name                = var.name
  desired_capacity    = var.desired
  min_size            = var.min
  max_size            = var.max
  vpc_zone_identifier = var.subnet_ids
  health_check_type   = "ELB"
  health_check_grace_period = 120
  target_group_arns   = [aws_lb_target_group.grpc.arn, aws_lb_target_group.web.arn]
  launch_template { id = aws_launch_template.node.id, version = "$Latest" }
  instance_refresh { strategy = "Rolling", preferences { min_healthy_percentage = 66 } }
  tag { key = "conveyor-cluster", value = var.name, propagate_at_launch = true }
}

# Give a terminating instance time to drain before it is torn down.
resource "aws_autoscaling_lifecycle_hook" "drain" {
  name                   = "${var.name}-drain"
  autoscaling_group_name = aws_autoscaling_group.nodes.name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"
  heartbeat_timeout      = var.drain_seconds + 30
  default_result         = "CONTINUE"
}

output "nlb_dns" { value = aws_lb.nlb.dns_name }
