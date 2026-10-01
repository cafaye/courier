# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :courier,
  ecto_repos: [Courier.Repo],
  generators: [timestamp_type: :utc_datetime],
  # The environment name, as data, because `Mix.env/0` is not available inside a
  # RELEASE and `System.get_env("MIX_ENV")` is not set there either. `config_env/0`
  # here runs at compile time and the value is baked into the release.
  #
  # `Courier.MailerAdapter` reads this rather than guessing: without it the
  # adapter boot gate would have no way to tell a production boot from a test
  # one, and its default has to be `:prod` — the safe direction, since guessing
  # `:dev` would let a release configure the silent adapter.
  environment: config_env()

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

# `api_client: false` is still correct, and now for a real reason rather than
# because no provider had landed. SMTP is the adapter courier ships, and
# `Swoosh.Adapters.SMTP` speaks the protocol over `gen_smtp` — it never calls
# Swoosh's HTTP client, so leaving this false keeps a dependency courier does not
# use out of the release. It would only need to change for an HTTP-API provider
# (Postmark, SendGrid, Resend), and none of those is configured: they all have an
# SMTP front, and one adapter is one fewer credential path to keep out of logs.
config :swoosh, api_client: false

# Job queue. courier's only queue is the outbox relay (`ProcessOutboxWorker`);
# nothing else is scheduled yet.
config :courier, Oban,
  repo: Courier.Repo,
  queues: [outbox: 10, webhooks: 5]

# Outbox relay tuning. Read at runtime, not compiled in, so a deployment can
# change batch size without a rebuild.
config :courier, :outbox,
  batch_size: 50,
  max_attempts: 10

# Outbound webhooks. Everything here is read at runtime, not compiled in, because
# all of it is a decision an operator has to be able to see and change without a
# rebuild — and PLAN.md §7 requires the budget to be bounded, which is only true
# if the bound is a number somebody can point at.
config :courier, :webhooks,
  # Eight attempts, five minutes apart at first, doubling, capped at six hours,
  # plus up to 25% jitter. A full budget spans roughly sixteen hours: the spec's
  # §Deliverability asks for "a retry schedule spanning multiple days", and this
  # is the same shape at a scale one courier-sized service can defend, without
  # keeping a dead endpoint's deliveries alive for a week.
  max_attempts: 8,
  backoff_base_seconds: 300,
  backoff_cap_seconds: 21_600,
  jitter_divisor: 4,
  # Consecutive failures before the circuit opens and the endpoint is disabled
  # with a reason. The spec §Deliverability says a consumer failing "consistently
  # over a long period of time" should have future delivery disabled; five is
  # courier's answer to "consistently", with the retry budget above deciding how
  # long that takes per delivery.
  circuit_threshold: 5,
  # The attempt timeout. Spec §Request timeouts asks for 15–30s; the low end,
  # because a delivery holding a worker is a delivery nobody else gets.
  timeout_ms: 15_000,
  connect_timeout_ms: 5_000,
  # How many outbox events one dispatch run fans out. Bounded so a large backlog
  # is worked through in batches rather than in one transaction that holds row
  # locks across the whole table.
  dispatch_batch_size: 100,
  # How many due deliveries one send run attempts. Bounded for the same reason,
  # and smaller than the dispatch batch because each of these makes a network call
  # and a hundred concurrent requests to a hundred different customers is a burst
  # courier's own egress gets shaped for.
  delivery_batch_size: 25

# The resolver the SSRF guard checks addresses with. Overridden in test so a URL
# check never depends on what a real resolver says about a real name.
config :courier, :dns_resolver, Courier.Webhooks.Dns.System

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
