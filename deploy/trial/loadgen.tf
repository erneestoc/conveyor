# Load generators for the fleet test: Fargate tasks running the Conveyor image with a corpus
# of real builds baked in (deploy/trial/images/README.md), each replaying N concurrent BES
# streams through the NLB over TLS, the way real Bazel clients arrive. Run with
# `aws ecs run-task` (bench/fleet.sh); the summary lands in CloudWatch Logs.
resource "aws_ecs_task_definition" "loadgen" {
  family                   = "${var.name}-loadgen"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 2048
  memory                   = 8192
  execution_role_arn       = aws_iam_role.task_exec.arn
  task_role_arn            = aws_iam_role.task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }
  container_definitions = jsonencode([{
    name      = "loadgen"
    image     = "${aws_ecr_repository.conveyor.repository_url}:loadgen"
    essential = true
    command   = ["bin/conveyor", "eval", "Conveyor.Loadgen.Fleet.main()"]
    environment = [
      { name = "LOADGEN_HOSTS", value = "${var.conveyor_host}:1985" },
      # 125 streams per 8 GB task: 250 ran out of memory (bench/fleet.sh overrides this).
      { name = "LOADGEN_ARGS", value = "--tls --streams 125 --duration-s 600 --delay-ms 500 --retries 5" },
      # The release's runtime config insists on these even for `eval`; the generator opens no database.
      { name = "DATABASE_URL", value = "ecto://none:none@localhost/none" },
      { name = "SECRET_KEY_BASE", value = "loadgen-no-web-server-loadgen-no-web-server-loadgen-no-web-server-0000" },
      { name = "PHX_HOST", value = "localhost" },
      { name = "SSM_PREFIX", value = "/${var.name}" },
      { name = "AWS_REGION", value = var.region }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.builders.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "loadgen"
      }
    }
  }])
}
