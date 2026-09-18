defmodule Build.Bazel.Semver.SemVer do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.semver.SemVer",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :major, 1, type: :int32
  field :minor, 2, type: :int32
  field :patch, 3, type: :int32
  field :prerelease, 4, type: :string
end
