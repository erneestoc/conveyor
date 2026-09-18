defmodule Devtools.Build.Lib.Packages.Metrics.PackageLoadMetrics do
  @moduledoc false

  use Protobuf,
    full_name: "devtools.build.lib.packages.metrics.PackageLoadMetrics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :name, 1, optional: true, type: :string

  field :load_duration, 2,
    optional: true,
    type: Google.Protobuf.Duration,
    json_name: "loadDuration"

  field :num_targets, 3, optional: true, type: :uint64, json_name: "numTargets"
  field :computation_steps, 4, optional: true, type: :uint64, json_name: "computationSteps"
  field :num_transitive_loads, 5, optional: true, type: :uint64, json_name: "numTransitiveLoads"
  field :package_overhead, 6, optional: true, type: :uint64, json_name: "packageOverhead"

  field :glob_filesystem_operation_cost, 7,
    optional: true,
    type: :uint64,
    json_name: "globFilesystemOperationCost"
end
