output "conveyor_url" { value = "https://${var.conveyor_host}" }
output "bes_backend" { value = "grpcs://${var.conveyor_host}:1985" }
output "admin_token" {
  value     = random_password.admin_token.result
  sensitive = true
}
output "nlb_dns" { value = aws_lb.nlb.dns_name }
output "ecr_conveyor" { value = aws_ecr_repository.conveyor.repository_url }
output "ecr_builder" { value = aws_ecr_repository.builder.repository_url }
output "ecr_nl_worker" { value = aws_ecr_repository.nl_worker.repository_url }
output "nl_control_ip" { value = var.rbe_enabled ? aws_eip.nl[0].public_ip : null }
output "ecs_cluster" { value = aws_ecs_cluster.builders.name }
output "task_definition" { value = aws_ecs_task_definition.builder.arn }
output "builder_subnets" { value = local.subnets }
output "builder_sg" { value = aws_security_group.builders.id }
output "conveyor_asg" { value = aws_autoscaling_group.conveyor.name }
output "ca_cert" { value = tls_self_signed_cert.ca.cert_pem }
