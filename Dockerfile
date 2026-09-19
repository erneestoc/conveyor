# Conveyor release image. Build: docker build -t conveyor:0.1.0 .
ARG ELIXIR_VERSION=1.20.3
ARG OTP_VERSION=29.0.5
ARG DEBIAN_VERSION=bookworm-20250908-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder
RUN apt-get update -y && apt-get install -y build-essential git curl \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
ENV MIX_ENV=prod
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile
COPY priv priv
COPY lib lib
COPY assets assets
RUN mix assets.setup && mix assets.deploy
RUN mix compile
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE}
RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates curl \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8
WORKDIR /app
RUN useradd --create-home --uid 1000 conveyor && chown conveyor /app && mkdir -p /var/lib/conveyor/blobs && chown conveyor /var/lib/conveyor/blobs
USER conveyor
COPY --from=builder --chown=conveyor:conveyor /app/_build/prod/rel/conveyor ./
ENV PHX_SERVER=true PORT=4000 GRPC_PORT=1985 BLOB_DIR=/var/lib/conveyor/blobs
EXPOSE 4000 1985
# Migrations run on every boot; they are idempotent and take the advisory lock Ecto uses.
CMD ["sh", "-c", "bin/conveyor eval 'Conveyor.Release.migrate()' && exec bin/conveyor start"]
