defmodule Blaze.InvocationPolicy.SetValue.Behavior do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "blaze.invocation_policy.SetValue.Behavior",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :UNDEFINED, 0
  field :ALLOW_OVERRIDES, 1
  field :APPEND, 2
  field :FINAL_VALUE_IGNORE_OVERRIDES, 3
  field :FINAL_VALUE_THROW_ON_OVERRIDE, 4
end

defmodule Blaze.InvocationPolicy.InvocationPolicy do
  @moduledoc false

  use Protobuf,
    full_name: "blaze.invocation_policy.InvocationPolicy",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :flag_policies, 1,
    repeated: true,
    type: Blaze.InvocationPolicy.FlagPolicy,
    json_name: "flagPolicies"

  field :strategy_policy, 2,
    optional: true,
    type: Blaze.StrategyPolicy.StrategyPolicy,
    json_name: "strategyPolicy"
end

defmodule Blaze.InvocationPolicy.FlagPolicy do
  @moduledoc false

  use Protobuf,
    full_name: "blaze.invocation_policy.FlagPolicy",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  oneof(:operation, 0)

  field :flag_name, 1, optional: true, type: :string, json_name: "flagName"
  field :commands, 2, repeated: true, type: :string

  field :set_value, 3,
    optional: true,
    type: Blaze.InvocationPolicy.SetValue,
    json_name: "setValue",
    oneof: 0

  field :use_default, 4,
    optional: true,
    type: Blaze.InvocationPolicy.UseDefault,
    json_name: "useDefault",
    oneof: 0

  field :disallow_values, 5,
    optional: true,
    type: Blaze.InvocationPolicy.DisallowValues,
    json_name: "disallowValues",
    oneof: 0

  field :allow_values, 6,
    optional: true,
    type: Blaze.InvocationPolicy.AllowValues,
    json_name: "allowValues",
    oneof: 0

  field :custom_error_message, 7, optional: true, type: :string, json_name: "customErrorMessage"
end

defmodule Blaze.InvocationPolicy.SetValue do
  @moduledoc false

  use Protobuf,
    full_name: "blaze.invocation_policy.SetValue",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :flag_value, 1, repeated: true, type: :string, json_name: "flagValue"
  field :behavior, 4, optional: true, type: Blaze.InvocationPolicy.SetValue.Behavior, enum: true
end

defmodule Blaze.InvocationPolicy.UseDefault do
  @moduledoc false

  use Protobuf,
    full_name: "blaze.invocation_policy.UseDefault",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2
end

defmodule Blaze.InvocationPolicy.DisallowValues do
  @moduledoc false

  use Protobuf,
    full_name: "blaze.invocation_policy.DisallowValues",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  oneof(:replacement_value, 0)

  field :disallowed_values, 1, repeated: true, type: :string, json_name: "disallowedValues"
  field :new_value, 3, optional: true, type: :string, json_name: "newValue", oneof: 0

  field :use_default, 4,
    optional: true,
    type: Blaze.InvocationPolicy.UseDefault,
    json_name: "useDefault",
    oneof: 0
end

defmodule Blaze.InvocationPolicy.AllowValues do
  @moduledoc false

  use Protobuf,
    full_name: "blaze.invocation_policy.AllowValues",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  oneof(:replacement_value, 0)

  field :allowed_values, 1, repeated: true, type: :string, json_name: "allowedValues"
  field :new_value, 3, optional: true, type: :string, json_name: "newValue", oneof: 0

  field :use_default, 4,
    optional: true,
    type: Blaze.InvocationPolicy.UseDefault,
    json_name: "useDefault",
    oneof: 0
end
