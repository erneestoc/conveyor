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
    field :byte_size, :integer
    field :payload, :binary
    # Blob mode (PLAN §25 step 2): the bytes live in a raw-log object, not in the row.
    field :object_key, :string
    field :object_offset, :integer
    field :object_length, :integer
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
    # Blob mode (PLAN §25 step 2): the bytes live in a raw-log object, not in the row.
    field :object_key, :string
    field :object_offset, :integer
    field :object_length, :integer
    field :inserted_at, :utc_datetime_usec
  end
end
