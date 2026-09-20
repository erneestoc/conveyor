# Two images from one toolchain base so that remote execution sees the same compilers at
# the same paths as the machine that configured the build:
#   docker buildx build --platform linux/amd64 --target builder  -t <ecr>/builder:latest --push images
#   docker buildx build --platform linux/amd64 --target nl-worker -t <ecr>/nativelink-worker:latest --push images
FROM ubuntu:24.04 AS base
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg unzip zip xz-utils patch file \
      build-essential gcc g++ clang lld libc++-dev libc++abi-dev \
      python3 python3-dev python-is-python3 \
      openjdk-21-jdk-headless \
      zlib1g-dev libssl-dev pkg-config cmake ninja-build autoconf automake libtool \
    && rm -rf /var/lib/apt/lists/*

FROM ghcr.io/tracemachina/nativelink:v1.7.1 AS nl

FROM base AS nl-worker
COPY --from=nl /nix /nix
RUN ln -s $(ls -d /nix/store/*-nativelink-*/bin/nativelink | head -1) /usr/local/bin/nativelink \
    && nativelink --version
ENTRYPOINT ["/usr/local/bin/nativelink"]

FROM base AS builder
ARG BAZELISK_VERSION=v1.27.0
RUN curl -fsSL -o /usr/local/bin/bazel \
      https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-amd64 \
    && chmod +x /usr/local/bin/bazel \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip \
    && unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscli.zip
RUN useradd -m -u 1000 -s /bin/bash builder 2>/dev/null || true
COPY bes-upload-profile /usr/local/bin/bes-upload-profile
COPY build.sh /usr/local/bin/build.sh
RUN chmod +x /usr/local/bin/bes-upload-profile /usr/local/bin/build.sh
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/build.sh"]
