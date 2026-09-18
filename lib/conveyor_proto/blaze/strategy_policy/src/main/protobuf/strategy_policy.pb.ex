defmodule Blaze.StrategyPolicy.StrategyPolicy do
  @moduledoc false

  use Protobuf,
    full_name: "blaze.strategy_policy.StrategyPolicy",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :mnemonic_policy, 1,
    optional: true,
    type: Blaze.StrategyPolicy.MnemonicPolicy,
    json_name: "mnemonicPolicy"

  field :dynamic_remote_policy, 2,
    optional: true,
    type: Blaze.StrategyPolicy.MnemonicPolicy,
    json_name: "dynamicRemotePolicy"

  field :dynamic_local_policy, 3,
    optional: true,
    type: Blaze.StrategyPolicy.MnemonicPolicy,
    json_name: "dynamicLocalPolicy"
end

defmodule Blaze.StrategyPolicy.MnemonicPolicy do
  @moduledoc false

  use Protobuf,
    full_name: "blaze.strategy_policy.MnemonicPolicy",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :default_allowlist, 1, repeated: true, type: :string, json_name: "defaultAllowlist"

  field :strategy_allowlist, 2,
    repeated: true,
    type: Blaze.StrategyPolicy.StrategiesForMnemonic,
    json_name: "strategyAllowlist"
end

defmodule Blaze.StrategyPolicy.StrategiesForMnemonic do
  @moduledoc false

  use Protobuf,
    full_name: "blaze.strategy_policy.StrategiesForMnemonic",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :mnemonic, 1, optional: true, type: :string
  field :strategy, 2, repeated: true, type: :string
end
