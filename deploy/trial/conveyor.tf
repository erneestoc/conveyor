resource "aws_s3_bucket" "blobs" {
  bucket        = "${var.name}-blobs-${data.aws_caller_identity.me.account_id}"
  force_destroy = true
}

resource "aws_iam_role" "conveyor" {
  name               = "${var.name}-conveyor"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}
resource "aws_iam_role_policy_attachment" "conveyor_ssm" {
  role       = aws_iam_role.conveyor.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy" "conveyor" {
  role = aws_iam_role.conveyor.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"], Resource = [aws_s3_bucket.blobs.arn, "${aws_s3_bucket.blobs.arn}/*"] },
      { Effect = "Allow", Action = ["ec2:DescribeInstances", "ec2:DescribeAddresses"], Resource = "*" },
      # The Caddy edge: the node attaches the stack's Elastic IP to itself at boot.
      { Effect = "Allow", Action = ["ec2:AssociateAddress"], Resource = "*",
      Condition = { StringEquals = { "aws:ResourceTag/project" = "conveyor-trial" } } },
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"], Resource = "*" },
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "*" }
    ]
  })
}
resource "aws_iam_instance_profile" "conveyor" {
  name = "${var.name}-conveyor"
  role = aws_iam_role.conveyor.name
}

resource "aws_security_group" "lb" {
  name   = "${var.name}-lb"
  vpc_id = data.aws_vpc.default.id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 1985
    to_port     = 1985
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "conveyor" {
  name   = "${var.name}-conveyor"
  vpc_id = data.aws_vpc.default.id
  ingress {
    from_port       = 4000
    to_port         = 4000
    protocol        = "tcp"
    security_groups = [aws_security_group.lb.id]
  }
  ingress {
    from_port       = 1985
    to_port         = 1985
    protocol        = "tcp"
    security_groups = [aws_security_group.lb.id]
  }
  # Caddy edge: the node itself terminates TLS (80 for the ACME challenge, 443, 1985).
  dynamic "ingress" {
    for_each = var.edge == "caddy" ? [80, 443, 1985] : []
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  ingress {
    description = "Erlang distribution between nodes"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name   = "${var.name}-db"
  vpc_id = data.aws_vpc.default.id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.conveyor.id]
  }
}

resource "aws_db_subnet_group" "db" {
  name       = var.name
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "db" {
  identifier                   = var.name
  engine                       = "postgres"
  engine_version               = "17"
  instance_class               = var.db_instance_class
  allocated_storage            = 100
  storage_type                 = "gp3"
  db_name                      = "conveyor"
  username                     = "conveyor"
  password                     = random_password.db.result
  db_subnet_group_name         = aws_db_subnet_group.db.name
  vpc_security_group_ids       = [aws_security_group.db.id]
  publicly_accessible          = false
  skip_final_snapshot          = true
  apply_immediately            = true
  backup_retention_period      = 1
  performance_insights_enabled = false
  parameter_group_name         = aws_db_parameter_group.db.name
  snapshot_identifier          = var.db_snapshot_identifier
}

resource "aws_db_parameter_group" "db" {
  name   = var.name
  family = "postgres17"
  parameter {
    name         = "max_connections"
    value        = "400"
    apply_method = "pending-reboot"
  }
  # The release verifies the RDS certificate (DATABASE_SSL=true with the global bundle).
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

# TLS certificate for the UI and the BES endpoint, validated through Route53.
resource "aws_acm_certificate" "conveyor" {
  domain_name       = var.conveyor_host
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}
resource "aws_route53_record" "conveyor_validation" {
  for_each = { for o in aws_acm_certificate.conveyor.domain_validation_options : o.domain_name => o }
  zone_id  = var.zone_id
  name     = each.value.resource_record_name
  type     = each.value.resource_record_type
  ttl      = 60
  records  = [each.value.resource_record_value]
}
resource "aws_acm_certificate_validation" "conveyor" {
  certificate_arn         = aws_acm_certificate.conveyor.arn
  validation_record_fqdns = [for r in aws_route53_record.conveyor_validation : r.fqdn]
}

resource "aws_lb" "nlb" {
  count              = var.edge == "nlb" ? 1 : 0
  name               = substr("${var.name}-nlb", 0, 32)
  load_balancer_type = "network"
  subnets            = local.subnets
  security_groups    = [aws_security_group.lb.id]
  # Off by default: a connection arriving in a zone without a healthy node would hang.
  enable_cross_zone_load_balancing = true
}
resource "aws_lb_target_group" "web" {
  count                = var.edge == "nlb" ? 1 : 0
  name                 = substr("${var.name}-web", 0, 32)
  port                 = 4000
  protocol             = "TCP"
  vpc_id               = data.aws_vpc.default.id
  deregistration_delay = var.drain_seconds
  health_check {
    protocol = "HTTP"
    path     = "/health/ready"
    interval = 10
  }
}
resource "aws_lb_target_group" "grpc" {
  count                = var.edge == "nlb" ? 1 : 0
  name                 = substr("${var.name}-grpc", 0, 32)
  port                 = 1985
  protocol             = "TCP"
  vpc_id               = data.aws_vpc.default.id
  deregistration_delay = var.drain_seconds
  health_check {
    protocol = "HTTP"
    port     = "4000"
    path     = "/health/ready"
    interval = 10
  }
}
resource "aws_lb_listener" "web" {
  count             = var.edge == "nlb" ? 1 : 0
  load_balancer_arn = aws_lb.nlb[0].arn
  port              = 443
  protocol          = "TLS"
  certificate_arn   = aws_acm_certificate_validation.conveyor.certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web[0].arn
  }
}
resource "aws_lb_listener" "grpc" {
  count             = var.edge == "nlb" ? 1 : 0
  load_balancer_arn = aws_lb.nlb[0].arn
  port              = 1985
  protocol          = "TLS"
  certificate_arn   = aws_acm_certificate_validation.conveyor.certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  alpn_policy       = "HTTP2Preferred"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grpc[0].arn
  }
}
resource "aws_route53_record" "conveyor" {
  count   = var.edge == "nlb" ? 1 : 0
  zone_id = var.zone_id
  name    = var.conveyor_host
  type    = "A"
  alias {
    name                   = aws_lb.nlb[0].dns_name
    zone_id                = aws_lb.nlb[0].zone_id
    evaluate_target_health = false
  }
}

# Caddy edge: a stable address the single node claims at boot; DNS points at it.
resource "aws_eip" "conveyor" {
  count  = var.edge == "caddy" ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.name}-conveyor" }
}
resource "aws_route53_record" "conveyor_eip" {
  count   = var.edge == "caddy" ? 1 : 0
  zone_id = var.zone_id
  name    = var.conveyor_host
  type    = "A"
  ttl     = 60
  records = [aws_eip.conveyor[0].public_ip]
}

resource "aws_launch_template" "conveyor" {
  name_prefix   = "${var.name}-conveyor-"
  image_id      = data.aws_ssm_parameter.al2023_arm64.value
  instance_type = var.conveyor_instance_type
  iam_instance_profile { name = aws_iam_instance_profile.conveyor.name }
  vpc_security_group_ids = [aws_security_group.conveyor.id]
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 30
      volume_type = "gp3"
    }
  }
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-conveyor", conveyor-cluster = var.name }
  }
  user_data = base64encode(templatefile("${path.module}/templates/conveyor.sh.tftpl", {
    ecr             = local.ecr
    region          = var.region
    image           = "${aws_ecr_repository.conveyor.repository_url}:${var.conveyor_image_tag}"
    database_url    = "ecto://conveyor:${random_password.db.result}@${aws_db_instance.db.address}/conveyor"
    secret_key_base = random_password.secret_key_base.result
    release_cookie  = random_password.release_cookie.result
    admin_token     = random_password.admin_token.result
    phx_host        = var.conveyor_host
    bucket          = aws_s3_bucket.blobs.bucket
    name            = var.name
    drain_seconds   = var.drain_seconds
    rbe_ca          = tls_self_signed_cert.ca.cert_pem
    edge            = var.edge
    eip_allocation  = var.edge == "caddy" ? aws_eip.conveyor[0].id : ""
  }))
}

resource "aws_autoscaling_group" "conveyor" {
  name                = "${var.name}-conveyor"
  desired_capacity    = var.conveyor_count
  min_size            = 0
  max_size            = 6
  vpc_zone_identifier = local.subnets
  target_group_arns   = var.edge == "nlb" ? [aws_lb_target_group.web[0].arn, aws_lb_target_group.grpc[0].arn] : []
  # EC2 health only: the balancer's readiness check depends on the database, and a slow
  # database made the group replace healthy nodes during the soak. Docker's restart
  # policy brings a crashed container back; routing is the balancer's decision.
  health_check_type         = "EC2"
  health_check_grace_period = 300
  launch_template {
    id      = aws_launch_template.conveyor.id
    version = "$Latest"
  }
  instance_refresh {
    strategy = "Rolling"
    preferences { min_healthy_percentage = var.edge == "nlb" ? 50 : 0 }
  }
  tag {
    key                 = "conveyor-cluster"
    value               = var.name
    propagate_at_launch = true
  }
  lifecycle {
    precondition {
      condition     = var.edge == "nlb" || var.conveyor_count <= 1
      error_message = "the caddy edge serves one node; use edge = nlb for more"
    }
  }
}
