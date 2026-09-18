defmodule Conveyor.Invocations.EventSegment do
  @moduledoc "A compressed batch of raw BEP events (varint-delimited protobuf, zstd)."
  use Ecto.Schema

  @primary_key false
  schema "event_segments" do
    field :invocation_id, :binary_id, primary_key: true
    field :day, :date, primary_key: true
    field :first_seq, :integer, primary_key: true
    field :last_seq, :integer
    field :count, :integer
    field :kinds, {:array, :string}, default: []
    field :byte_size, :integer
    field :payload, :binary
    field :inserted_at, :utc_datetime_usec
  end
end

defmodule Conveyor.Invocations.LogSegment do
  @moduledoc "A compressed batch of build log text (Progress stdout/stderr, zstd)."
  use Ecto.Schema

  @primary_key false
  schema "log_segments" do
    field :invocation_id, :binary_id, primary_key: true
    field :day, :date, primary_key: true
    field :first_seq, :integer, primary_key: true
    field :last_seq, :integer
    field :byte_offset, :integer
    field :line_offset, :integer
    field :byte_size, :integer
    field :line_count, :integer
    field :data, :binary
    field :inserted_at, :utc_datetime_usec
  end
end
