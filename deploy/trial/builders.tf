# ECS Fargate tasks that clone a project and stream one build into Conveyor.
resource "aws_ecs_cluster" "builders" {
  name = "${var.name}-builders"
}
resource "aws_cloudwatch_log_group" "builders" {
  name              = "/${var.name}/builders"
  retention_in_days = 14
}
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "task_exec" {
  name               = "${var.name}-task-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}
resource "aws_iam_role_policy_attachment" "task_exec" {
  role       = aws_iam_role.task_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}
resource "aws_iam_role_policy" "task" {
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ssm:GetParameter", "ssm:GetParameters"], Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.me.account_id}:parameter/${var.name}/*" }
    ]
  })
}

resource "aws_ecs_task_definition" "builder" {
  family                   = "${var.name}-builder"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 8192
  memory                   = 32768
  execution_role_arn       = aws_iam_role.task_exec.arn
  task_role_arn            = aws_iam_role.task.arn
  ephemeral_storage { size_in_gib = 200 }
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name      = "builder"
    image     = "${aws_ecr_repository.builder.repository_url}:latest"
    essential = true
    environment = [
      { name = "CONVEYOR_SERVER", value = "https://${var.conveyor_host}" },
      { name = "BES_BACKEND", value = "grpcs://${var.conveyor_host}:1985" },
      { name = "REMOTE_CACHE", value = "grpcs://${var.cache_host}:50051" },
      { name = "REMOTE_EXECUTOR", value = "grpcs://${var.rbe_host}:50052" },
      { name = "SSM_PREFIX", value = "/${var.name}" },
      { name = "AWS_REGION", value = var.region }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.builders.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "build"
      }
    }
  }])
}
