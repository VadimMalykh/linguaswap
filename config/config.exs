# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :linguaswap, :scopes,
  user: [
    default: true,
    module: Linguaswap.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :email,
    test_data_fixture: Linguaswap.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :linguaswap,
  ecto_repos: [Linguaswap.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :linguaswap, LinguaswapWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LinguaswapWeb.ErrorHTML, json: LinguaswapWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Linguaswap.PubSub,
  live_view: [signing_salt: "EZ2/Ba0z"]

# The Claude API client used to generate dictionary entries (Phase 4).
#
# The key is read from the environment at runtime (config/runtime.exs), so a
# build without one simply has no generation: `Linguaswap.LLM` refuses to make
# a request rather than failing part-way through a dictionary.
#
# The two limits below are the cost controls. `requests_per_minute` paces a
# generation run, and `cost_cap_usd` is the total a running node may spend —
# for a `mix` task, that is the whole run.
# `:provider` is the seam: any module implementing `Linguaswap.LLM.Provider`
# can answer instead, and `Linguaswap.LLM.Provider.OpenAICompatible` covers
# every `/v1/chat/completions` service (OpenAI, OpenRouter, a local Ollama).
#
# `:effort` is the cost dial. Thinking tokens bill as output and dominate a
# generation run, and filling in dictionary forms is recall rather than
# reasoning, so this work runs at the bottom of the range.
config :linguaswap, Linguaswap.LLM,
  provider: Linguaswap.LLM.Provider.Anthropic,
  model: "claude-opus-5",
  effort: :low,
  requests_per_minute: 20,
  cost_cap_usd: 5.0

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :linguaswap, Linguaswap.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  linguaswap: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  linguaswap: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
