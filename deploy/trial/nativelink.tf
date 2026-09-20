# Private CA and a server certificate for NativeLink (CAS + scheduler + worker API).
resource "tls_private_key" "ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}
resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 24 * 90
  allowed_uses          = ["cert_signing", "crl_signing", "digital_signature"]
  subject {
    common_name  = "Conveyor trial CA"
    organization = "algobien"
  }
}
resource "tls_private_key" "nl" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}
resource "tls_cert_request" "nl" {
  private_key_pem = tls_private_key.nl.private_key_pem
  dns_names       = [var.rbe_host, var.cache_host, "localhost"]
  ip_addresses    = ["127.0.0.1"]
  subject {
    common_name = var.rbe_host
  }
}
resource "tls_locally_signed_cert" "nl" {
  cert_request_pem      = tls_cert_request.nl.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 24 * 90
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
}

# The server key travels through SSM, not user-data.
resource "aws_ssm_parameter" "nl_key" {
  name  = "/${var.name}/nativelink/server.key"
  type  = "SecureString"
  value = tls_private_key.nl.private_key_pem
}
resource "aws_ssm_parameter" "nl_cert" {
  name  = "/${var.name}/nativelink/server.crt"
  type  = "String"
  value = tls_locally_signed_cert.nl.cert_pem
}
resource "aws_ssm_parameter" "ca_cert" {
  name  = "/${var.name}/ca.crt"
  type  = "String"
  value = tls_self_signed_cert.ca.cert_pem
}

resource "aws_iam_role" "nl" {
  name               = "${var.name}-nativelink"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}
resource "aws_iam_role_policy_attachment" "nl_ssm" {
  role       = aws_iam_role.nl.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy" "nl" {
  role = aws_iam_role.nl.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ssm:GetParameter", "ssm:GetParameters"], Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.me.account_id}:parameter/${var.name}/*" },
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"], Resource = "*" }
    ]
  })
}
resource "aws_iam_instance_profile" "nl" {
  name = "${var.name}-nativelink"
  role = aws_iam_role.nl.name
}

resource "aws_security_group" "builders" {
  name   = "${var.name}-builders"
  vpc_id = data.aws_vpc.default.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "nl_workers" {
  name   = "${var.name}-nl-workers"
  vpc_id = data.aws_vpc.default.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "nl_control" {
  name   = "${var.name}-nl-control"
  vpc_id = data.aws_vpc.default.id
  # CAS (50051) and scheduler (50052): builders, Conveyor (profile fetches), laptops.
  ingress {
    from_port       = 50051
    to_port         = 50052
    protocol        = "tcp"
    security_groups = [aws_security_group.builders.id, aws_security_group.conveyor.id, aws_security_group.nl_workers.id]
    cidr_blocks     = var.allow_cidrs
  }
  # Worker API (50061): workers only.
  ingress {
    from_port       = 50061
    to_port         = 50061
    protocol        = "tcp"
    security_groups = [aws_security_group.nl_workers.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_eip" "nl" {
  count  = var.rbe_enabled ? 1 : 0
  domain = "vpc"
}

resource "aws_instance" "nl_control" {
  count                       = var.rbe_enabled ? 1 : 0
  ami                         = data.aws_ssm_parameter.al2023_x86.value
  instance_type               = var.nl_control_type
  subnet_id                   = local.subnets[0]
  vpc_security_group_ids      = [aws_security_group.nl_control.id]
  iam_instance_profile        = aws_iam_instance_profile.nl.name
  associate_public_ip_address = true
  root_block_device {
    volume_size = var.nl_cas_gb + 20
    volume_type = "gp3"
    throughput  = 250
  }
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  user_data = templatefile("${path.module}/templates/nl-control.sh.tftpl", {
    name       = var.name
    region     = var.region
    rbe_host   = var.rbe_host
    cache_host = var.cache_host
    cas_bytes  = var.nl_cas_gb * 1000 * 1000 * 1000
    cas_json   = file("${path.module}/nativelink/cas.json5")
    sched_json = file("${path.module}/nativelink/scheduler.json5")
  })
  tags = { Name = "${var.name}-nl-control" }
}
resource "aws_eip_association" "nl" {
  count         = var.rbe_enabled ? 1 : 0
  instance_id   = aws_instance.nl_control[0].id
  allocation_id = aws_eip.nl[0].id
}
resource "aws_route53_record" "rbe" {
  count   = var.rbe_enabled ? 1 : 0
  zone_id = var.zone_id
  name    = var.rbe_host
  type    = "A"
  ttl     = 60
  records = [aws_eip.nl[0].public_ip]
}
resource "aws_route53_record" "cache" {
  count   = var.rbe_enabled ? 1 : 0
  zone_id = var.zone_id
  name    = var.cache_host
  type    = "A"
  ttl     = 60
  records = [aws_eip.nl[0].public_ip]
}

resource "aws_launch_template" "nl_worker" {
  count         = var.rbe_enabled ? 1 : 0
  name_prefix   = "${var.name}-nl-worker-"
  image_id      = data.aws_ssm_parameter.al2023_x86.value
  instance_type = var.nl_worker_type
  iam_instance_profile { name = aws_iam_instance_profile.nl.name }
  vpc_security_group_ids = [aws_security_group.nl_workers.id]
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 100
      volume_type = "gp3"
    }
  }
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-nl-worker" }
  }
  user_data = base64encode(templatefile("${path.module}/templates/nl-worker.sh.tftpl", {
    name        = var.name
    region      = var.region
    ecr         = local.ecr
    image       = "${aws_ecr_repository.nl_worker.repository_url}:latest"
    rbe_host    = var.rbe_host
    cache_host  = var.cache_host
    control_ip  = aws_instance.nl_control[0].private_ip
    worker_json = file("${path.module}/nativelink/worker.json5")
  }))
}
resource "aws_autoscaling_group" "nl_workers" {
  count               = var.rbe_enabled ? 1 : 0
  name                = "${var.name}-nl-workers"
  desired_capacity    = var.nl_workers
  min_size            = 0
  max_size            = 16
  vpc_zone_identifier = local.subnets
  launch_template {
    id      = aws_launch_template.nl_worker[0].id
    version = "$Latest"
  }
  instance_refresh {
    strategy = "Rolling"
    preferences { min_healthy_percentage = 0 }
  }
}
