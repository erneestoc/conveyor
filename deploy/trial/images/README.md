Images for the trial, built on a laptop and pushed to the ECR repositories Terraform creates:

    eval "$(aws ecr get-login-password | sed 's/^/echo /')" >/dev/null   # or:
    aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-1.amazonaws.com
    docker buildx build --platform linux/amd64 --target builder   -t <ecr>/conveyor-trial/builder:latest --push .
    docker buildx build --platform linux/amd64 --target nl-worker -t <ecr>/conveyor-trial/nativelink-worker:latest --push .

`build.sh` is the builder entrypoint (see its header for the environment it takes);
`bes-upload-profile` is a copy of `tools/bes-upload-profile`.
