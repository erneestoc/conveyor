defmodule Conveyor.Storage do
  @moduledoc "Boot-time storage preparation."

  require Logger

  @doc "Ensures partitions and the default project exist. Safe to run on every boot."
  def boot do
    Conveyor.Storage.Partitions.ensure()
    Conveyor.Projects.ensure_default_project!()
    :ok
  rescue
    e ->
      Logger.error("storage boot failed: #{Exception.message(e)}")
      :error
  end
end
