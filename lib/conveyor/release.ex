defmodule Conveyor.Release do
  @moduledoc "Release tasks: `bin/conveyor eval \"Conveyor.Release.migrate()\"` (also run on boot)."
  @app :conveyor

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  The Repo `:ssl` option from the environment: `false` unless `DATABASE_SSL` is `true`/`1`;
  then the server certificate is verified against `DATABASE_SSL_CA` (a PEM bundle such as
  the AWS RDS global bundle) or, when unset, the operating system's trust store, with the
  database host from `DATABASE_URL` as the expected name.
  """
  @spec database_ssl(map()) :: false | keyword()
  def database_ssl(env) do
    if Map.get(env, "DATABASE_SSL") in ~w(true 1) do
      host = env |> Map.get("DATABASE_URL", "") |> URI.parse() |> Map.get(:host)

      trust =
        case Map.get(env, "DATABASE_SSL_CA") do
          path when is_binary(path) and path != "" -> [cacertfile: path]
          _ -> [cacerts: :public_key.cacerts_get()]
        end

      [verify: :verify_peer, depth: 3, server_name_indication: sni(host)] ++ trust
    else
      false
    end
  end

  defp sni(host) when is_binary(host) and host != "", do: String.to_charlist(host)
  defp sni(_), do: :disable

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
