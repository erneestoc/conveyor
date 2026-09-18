defmodule FailureDetails.PbExtension do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.17.0"

  extend(Google.Protobuf.EnumValueOptions, :metadata, 1078,
    optional: true,
    type: FailureDetails.FailureDetailMetadata
  )
end
