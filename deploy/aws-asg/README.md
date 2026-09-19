# Conveyor on an EC2 auto-scaling group

Instances run the Conveyor container from user-data, discover each other through the
`conveyor-cluster=<name>` tag (`CLUSTER_STRATEGY=ec2`, instance role with
`ec2:DescribeInstances`), keep blobs in S3 (instance role), and sit behind a Network Load
Balancer: TCP 1985 for gRPC (TLS terminated on the instances or passed through) and TCP 443
for the UI. Health checks hit `/health/ready`, so draining instances leave rotation before
they stop; the ASG lifecycle hook gives them `SHUTDOWN_DRAIN_SECONDS`.

    terraform init
    terraform apply -var name=conveyor -var vpc_id=vpc-... -var 'subnet_ids=["subnet-a","subnet-b"]' \
      -var database_url=ecto://... -var secret_key_base=... -var release_cookie=... -var image=ghcr.io/example/conveyor:0.1.0

Scale-in: `terraform apply -var desired=2` (or an ASG policy). Node kill: terminate an
instance from the console; Bazel clients retry through the NLB onto the remaining nodes and
the persistence oracle (`mix conveyor.loadgen --verify`) shows zero loss.
