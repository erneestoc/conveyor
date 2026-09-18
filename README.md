# Conveyor

Self-hosted build observability for [Bazel](https://bazel.build). Conveyor is a
[Build Event Service](https://bazel.build/remote/bep) server with a real-time web UI:
point `--bes_backend` at it and every build shows up with its log, timeline, targets,
tests, cache statistics and metrics, filterable by any tag you attach with
`--build_metadata`.

Status: **pre-alpha, under active development.** See [PLAN.md](PLAN.md) for the roadmap.

## Development

Requirements: Elixir 1.20+ / OTP 29, Docker (for PostgreSQL), `protoc` and
`protoc-gen-elixir` only if you change the vendored protos.

```sh
docker compose -f docker-compose.dev.yml up -d   # PostgreSQL on 127.0.0.1:5440
mix setup
PORT=4000 mix phx.server                          # web on :4000, BES gRPC on :1985
```

Point a Bazel workspace at it:

```sh
bazel test //... \
  --bes_backend=grpc://localhost:1985 \
  --bes_results_url=http://localhost:4000/invocation/ \
  --build_metadata=USER=$USER --build_metadata=CI=false
```

Or replay a recorded build without Bazel:

```sh
mix conveyor.replay test/fixtures/bep/clean_build_and_test.bep --repeat 10 --concurrency 5
```

Fixtures under `test/fixtures/bep/` were recorded from `test/fixtures/workspace/` with
`--build_event_binary_file`. Regenerate the protobuf modules with `priv/protos/gen.sh`.

Run `mix precommit` before committing.

## License

MIT. Vendored protocol definitions from Bazel, googleapis and remote-apis are Apache-2.0;
their licenses are kept next to the `.proto` files under `priv/protos/`.
