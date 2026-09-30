# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :courier,
  ecto_repos: [Courier.Repo],
  generators: [timestamp_type: :utc_datetime]

# Transactional email.
#
# Courier composes mail and hands it to Swoosh; it never speaks to a provider
# protocol itself, so swapping providers is a config change and not a code
# change. The From address and the subject templates are here because they are
# the two things an operator should be able to reword without touching a
# module. config/runtime.exs overrides `from` from the environment at boot.
#
# Subjects are templates with `%{key}` placeholders, filled from the payload
# the platform hands courier (see `Courier.Mailers.subject/2`). A template that
# names a key the payload does not carry is a configuration error, not a mail
# with a hole in it.
config :courier, :mailing,
  from: {"caFaye", "no-reply@cafaye.com"},
  subjects: %{
    welcome: "Welcome to caFaye",
    password_reset: "Reset your caFaye password",
    team_invitation: "%{invited_by} invited you to join %{account_name}"
  }

# `api_client: false` is the load-bearing line: it stops Swoosh pulling in an
# HTTP client for provider calls that this packet does not make. When a
# provider lands, this becomes `Swoosh.ApiClient.Finch` (or Hackney) and the
# adapter is configured per environment.
config :swoosh, api_client: false

# Job queue. courier's only queue is the outbox relay (`ProcessOutboxWorker`);
# nothing else is scheduled yet.
config :courier, Oban,
  repo: Courier.Repo,
  queues: [outbox: 10]

# Outbox relay tuning. Read at runtime, not compiled in, so a deployment can
# change batch size without a rebuild.
config :courier, :outbox,
  batch_size: 50,
  max_attempts: 10

# Configure the endpoint
config :courier, CourierWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: CourierWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Courier.PubSub,
  live_view: [signing_salt: "hkUIdgF0"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
