defmodule Linguaswap.Repo do
  use Ecto.Repo,
    otp_app: :linguaswap,
    adapter: Ecto.Adapters.Postgres
end
