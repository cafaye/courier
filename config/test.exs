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
