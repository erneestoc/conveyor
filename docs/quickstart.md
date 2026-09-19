# Quick start

## With Docker Compose

```sh
git clone https://github.com/example/conveyor && cd conveyor
docker compose up -d
```

This starts PostgreSQL and Conveyor (built from the checkout; use the published image
`ghcr.io/example/conveyor:0.1.0` in your own compose file). Open
[http://localhost:4000](http://localhost:4000) and sign in with the `ADMIN_TOKEN` from
`docker-compose.yml`; change it and `SECRET_KEY_BASE` before exposing the service.

In **Settings**, create a project and an API key. Keys are shown once.

## Point Bazel at it

In any workspace:

```sh
bazel test //... \
  --bes_backend=grpc://localhost:1985 \
  --bes_results_url=http://localhost:4000/invocation/ \
  --bes_header=x-api-key=conveyor_... \
  --build_metadata=TEAM=infra --build_metadata=CI=false
```

Bazel prints `Streaming build results to: http://localhost:4000/invocation/<id>` as the
build starts; the page fills in live. Put the flags in `.bazelrc` to make them permanent
([Configure Bazel](bazel.md)).

## Without Docker

Requirements: Elixir 1.20 / OTP 29 and PostgreSQL 15+.

```sh
mix setup                                   # deps, database, assets
PORT=4000 mix phx.server                    # web on :4000, BES gRPC on :1985
mix conveyor.seed --replay 1500 --days 30   # optional: realistic data to browse
```

In development the BES endpoint accepts unauthenticated streams into the `default`
project. Set `BES_INGEST_AUTH=api_key` to require keys, as production does.

## Try it with recorded builds

No Bazel workspace at hand? Replay the recorded fixtures through the real pipeline,
optionally dropping connections mid-stream and verifying that every event landed once:

```sh
mix conveyor.replay test/fixtures/bep/*.bep --repeat 20 --concurrency 5 --drop-after 20 --verify
```

## Next

- [Production guide](production.md) for sizing, PostgreSQL settings and rollouts.
- [Kubernetes and Helm](kubernetes.md) to install on an existing cluster.
- [Sign-in and access](auth.md) to switch from the admin token to OpenID Connect.
