# Conveyor

Self-hosted build observability for [Bazel](https://bazel.build). Conveyor is a
[Build Event Service](https://bazel.build/remote/bep) server with a real-time web UI:
point `--bes_backend` at it and every build shows up with its log, timeline, targets,
tests, cache statistics and metrics, filterable by any tag you attach with
`--build_metadata`.

Status: **pre-alpha, under active development.** See [PLAN.md](PLAN.md) for the roadmap and [HANDOFF.md](HANDOFF.md) for the current state and how to resume work.

## Development

Requirements: Elixir 1.20+ / OTP 29, Docker (for PostgreSQL), `protoc` and
`protoc-gen-elixir` only if you change the vendored protos.

```sh
docker compose -f docker-compose.dev.yml up -d   # PostgreSQL on 127.0.0.1:5440
mix setup
PORT=4000 mix phx.server                          # web on :4000, BES gRPC on :1985
```

In development the BES endpoint accepts unauthenticated streams into the `default`
project (set `BES_INGEST_AUTH=api_key` to require keys). Point a Bazel workspace at it:

```sh
bazel test //... \
  --bes_backend=grpc://localhost:1985 \
  --bes_results_url=http://localhost:4000/invocation/ \
  --build_metadata=USER=$USER --build_metadata=CI=false
```

With API keys (production default), create a project and a key, then pass the key as a
header. Keys are shown once; only a hash is stored.

```sh
mix run -e 'IO.puts(elem(Conveyor.Projects.create_api_key(Conveyor.Projects.ensure_default_project!(), %{name: "laptop"}), 2))'
bazel test //... --bes_backend=grpc://localhost:1985 --bes_header=x-api-key=conveyor_...
```

Or replay a recorded build without Bazel, optionally simulating dropped connections and
verifying that everything was persisted exactly once:

```sh
mix conveyor.replay test/fixtures/bep/clean_build_and_test.bep --repeat 10 --concurrency 5 --drop-after 20 --verify
```

Fixtures under `test/fixtures/bep/` were recorded from `test/fixtures/workspace/` with
`--build_event_binary_file`. Regenerate the protobuf modules with `priv/protos/gen.sh`.

Run `mix precommit` before committing.

## License

MIT. Vendored protocol definitions from Bazel, googleapis and remote-apis are Apache-2.0;
their licenses are kept next to the `.proto` files under `priv/protos/`.
