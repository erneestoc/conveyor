defmodule CommandLine.CommandLine do
  @moduledoc false

  use Protobuf,
    full_name: "command_line.CommandLine",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :command_line_label, 1, type: :string, json_name: "commandLineLabel"
  field :sections, 2, repeated: true, type: CommandLine.CommandLineSection
end

defmodule CommandLine.CommandLineSection do
  @moduledoc false

  use Protobuf,
    full_name: "command_line.CommandLineSection",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof(:section_type, 0)

  field :section_label, 1, type: :string, json_name: "sectionLabel"
  field :chunk_list, 2, type: CommandLine.ChunkList, json_name: "chunkList", oneof: 0
  field :option_list, 3, type: CommandLine.OptionList, json_name: "optionList", oneof: 0
end

defmodule CommandLine.ChunkList do
  @moduledoc false

  use Protobuf,
    full_name: "command_line.ChunkList",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :chunk, 1, repeated: true, type: :string
end

defmodule CommandLine.OptionList do
  @moduledoc false

  use Protobuf,
    full_name: "command_line.OptionList",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :option, 1, repeated: true, type: CommandLine.Option
end

defmodule CommandLine.Option do
  @moduledoc false

  use Protobuf,
    full_name: "command_line.Option",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :combined_form, 1, type: :string, json_name: "combinedForm"
  field :option_name, 2, type: :string, json_name: "optionName"
  field :option_value, 3, type: :string, json_name: "optionValue"

  field :effect_tags, 4,
    repeated: true,
    type: Options.OptionEffectTag,
    json_name: "effectTags",
    enum: true

  field :metadata_tags, 5,
    repeated: true,
    type: Options.OptionMetadataTag,
    json_name: "metadataTags",
    enum: true

  field :source, 6, type: :string
end
