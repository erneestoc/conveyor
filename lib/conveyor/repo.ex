defmodule Conveyor.Repo do
  use Ecto.Repo,
    otp_app: :conveyor,
    adapter: Ecto.Adapters.Postgres
end
