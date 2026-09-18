# Third-party notices

Conveyor is MIT licensed. It vendors protocol definitions from the following
Apache-2.0 projects under `priv/protos/`; each directory keeps the upstream LICENSE.

| Directory | Project | Version |
|---|---|---|
| `priv/protos/bazel` | https://github.com/bazelbuild/bazel | see `priv/protos/VERSION` |
| `priv/protos/googleapis` | https://github.com/googleapis/googleapis | see `priv/protos/VERSION` |
| `priv/protos/remote-apis` | https://github.com/bazelbuild/remote-apis | see `priv/protos/VERSION` |

Elixir modules under `lib/conveyor_proto/` are generated from those files.
Runtime dependencies and their licenses are listed by `mix hex.info` / `mix deps`.
