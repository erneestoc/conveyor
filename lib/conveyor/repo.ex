defmodule Conveyor.Repo do
  use Ecto.Repo,
    otp_app: :conveyor,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Every session runs in UTC. The columns are `timestamp without time zone` holding UTC;
  statements that pass `timestamptz` parameters (the ingest writer's arrays) or call
  `now()` would otherwise be converted with the server's `TimeZone` setting, which is
  the operating system's on a self-hosted PostgreSQL (found on the bench cluster, UTC−7:
  the first execution of every action key was stored seven hours early and no execution
  was ever racing).
  """
  @impl true
  def init(_type, config) do
    {:ok,
     Keyword.update(
       config,
       :parameters,
       [timezone: "UTC"],
       &Keyword.put_new(&1, :timezone, "UTC")
     )}
  end
end
