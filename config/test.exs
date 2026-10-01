import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :courier, Courier.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "courier_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :courier, CourierWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "N0hG2os3k49qghyM9nsz+v7uuI6N8Msgch1e1YE9lmjC2n5bahmQKOrq2a5Up+aj",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Transactional email in test goes to `Swoosh.Adapters.Test`, which hands the
# message to the process that sent it. That is what makes `assert_email_sent/1`
# (Swoosh.TestAssertions) work without a provider, a relay, or a socket.
config :courier, Courier.Mailer, adapter: Swoosh.Adapters.Test

# Oban in `:manual` testing mode: jobs land in the database, nothing executes in
# the background. Both modes also silence plugin queries, which is what keeps the
# Ecto sandbox usable (guides/testing/testing.md).
config :courier, Oban, testing: :manual

# The relay publishes to a stand-in that hands each envelope back to the calling
# process, so a test can assert on what would have gone to NATS. The Gnat
# connection is a later packet.
config :courier, :nats_publisher, Courier.NatsPublisher.Noop

# A fixed sealing key, so a test can assert that a secret is *not* readable from
# the column without the assertion depending on which key the process booted
# with. Test-only: `config/runtime.exs` requires a real one from the environment
# and refuses to boot without it, and this value is in the repository.
config :courier, :secret_box_key, "Y291cmllci10ZXN0LW9ubHkta2V5LTMyLWJ5dGVzISE="

# The SSRF guard's resolver in test. `Courier.TestSupport.TestDns` answers from
# a table a test writes, so every URL in the suite — including ones pointing at
# `127.0.0.1` — is checked without a DNS lookup whose answer could differ
# between a laptop and CI. `{module, argument}` is the guard's convention for a
# resolver that needs to be told something.
config :courier, :dns_resolver, {Courier.TestSupport.TestDns, {:canned, ["93.184.216.34"]}}

# Webhook delivery in test goes to a double that records the request instead of
# opening a socket, so the assertions about what courier signs and sends are
# assertions about courier and not about a listener's timing. See
# `test/support/recording_sender.ex`.
config :courier, :webhook_sender, Courier.TestSupport.RecordingSender

# The principal resolver in test. It reads the account from a request header so
# the authorization matrix can be asserted over real requests; it is a stand-in
# for identity's JWT verifier and is only ever configured here. The shipped
# default, `Courier.Principal.Reject`, authenticates nobody — see
# `lib/courier_web/plugs/principal.ex`.
config :courier, :principal, Courier.TestSupport.HeaderResolver

# OpenTelemetry in test, and it is ON.
#
# The suite is where courier's redaction boundary is proved, so telemetry has to be
# on for the proof to mean anything: an allowlist that was never exercised because
# nothing was recorded is an allowlist nobody has checked.
#
# The exporter is `Courier.TestSpanExporter`, which writes into an ETS table
# instead of dialling a collector. Three reasons, and all three are the fleet's
# rules rather than preferences:
#
#   1. Nothing leaves the process. A test that dialled a collector would be a
#      network call in a suite whose rule is no sockets, and a suite that phones an
#      observability backend is a suite that phones an observability backend.
#   2. It is the REAL SDK with a REAL exporter swapped in, so a test reads the
#      payload a collector would have received rather than the test's idea of it.
#   3. `:otel_simple_processor` rather than the batch processor, so a span is
#      finished and exported by the time the request returns. A test that had to
#      wait for a flush timer would need a sleep, and a sleep is a guess about
#      someone else's interval that is wrong on the machine where it matters.
#
# The propagators and the sampler are set because the propagation tests need them
# to be the same two a deployment gets. `root: :always_on` and not
# `{:always_on, []}` — the latter is what kit's Elixir snippet says, it does not
# match this SDK's `otel_sampler:new/1`, and the resulting `:undef` takes the whole
# tracer provider down while its start result is discarded with `_ =`.
config :courier, :otel_exporter, Courier.TestSpanExporter

config :opentelemetry,
  text_map_propagators: [:trace_context, :baggage],
  sampler: {:parent_based, %{root: :always_on}},
  register_loaded_applications: false,
  create_application_tracers: false
