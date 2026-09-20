# Images are built on the laptop and pushed here (see images/README.md).
resource "aws_ecr_repository" "conveyor" {
  name         = "${var.name}/conveyor"
  force_delete = true
}
resource "aws_ecr_repository" "builder" {
  name         = "${var.name}/builder"
  force_delete = true
}
resource "aws_ecr_repository" "nl_worker" {
  name         = "${var.name}/nativelink-worker"
  force_delete = true
}

# A role every instance gets: SSM Session Manager (no SSH), ECR pulls, CloudWatch logs.
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
