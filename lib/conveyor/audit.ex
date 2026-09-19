defmodule Conveyor.Audit do
  @moduledoc """
  Append-only audit log for security-relevant actions: sign-ins, admin unlocks, project
  and API key changes, cache endpoint changes, uploads. Logging never raises: a failed
  insert is reported to the logger and the caller carries on.
  """
  import Ecto.Query
  require Logger

  alias Conveyor.Accounts.Scope
  alias Conveyor.Audit.Entry
  alias Conveyor.Projects.ApiKey
  alias Conveyor.Repo

  @type actor :: Scope.t() | ApiKey.t() | String.t()

  @doc """
  Records an action. `actor` is a scope (web), an API key (HTTP/gRPC APIs) or a string.
  Options: `:subject` (`{type, id}`), `:project_id`, `:ip`, `:metadata`.
  """
  @spec log(actor(), String.t(), keyword()) :: :ok
  def log(actor, action, opts \\ []) do
    {name, type} = describe(actor)
    {subject_type, subject_id} = Keyword.get(opts, :subject, {nil, nil})

    row = %{
      actor: name,
      actor_type: type,
      action: action,
      subject_type: subject_type,
      subject_id: subject_id && to_string(subject_id),
      project_id: Keyword.get(opts, :project_id),
      ip: Keyword.get(opts, :ip),
      metadata: Keyword.get(opts, :metadata, %{}),
      inserted_at: DateTime.utc_now()
    }

    case Repo.insert_all(Entry, [row]) do
      {1, _} -> :ok
      other -> Logger.error("audit insert failed: #{inspect(other)}")
    end

    :ok
  rescue
    e -> Logger.error("audit insert failed: #{Exception.message(e)}")
  end

  defp describe(%Scope{} = scope) do
    case scope do
      %{user: %{}} -> {Scope.actor(scope), "user"}
      %{admin_session?: true} -> {"admin-token", "admin_token"}
      _ -> {"anonymous", "anonymous"}
    end
  end

  defp describe(%ApiKey{key_id: key_id, name: name}), do: {"#{name} (#{key_id})", "api_key"}
  defp describe(name) when is_binary(name), do: {name, "system"}

  @doc "Most recent entries, newest first."
  @spec recent(pos_integer(), keyword()) :: [Entry.t()]
  def recent(limit \\ 50, opts \\ []) do
    query = from e in Entry, order_by: [desc: e.inserted_at, desc: e.id], limit: ^limit

    query =
      case Keyword.get(opts, :project_id) do
        nil -> query
        id -> where(query, [e], e.project_id == ^id)
      end

    Repo.all(query)
  end

  @doc "IP of a connection as a string."
  @spec ip(Plug.Conn.t()) :: String.t()
  def ip(%Plug.Conn{remote_ip: ip}), do: ip |> :inet.ntoa() |> to_string()
end
