import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/courier start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :courier, CourierWeb.Endpoint, server: true

  # **Both** endpoints, and the second one is not a copy-paste error. The error
  # endpoint declares `server: false` in `config/config.exs` so that a
  # `mix test` run and a `mix phx.server` run do not bind a second listener, which
  # is the right default; but a release that serves the customer API and does not
  # serve the ingest surface is a relay with no door.
  #
  # This is release-only breakage in the same family as the `Sentry` child-spec
  # mistake in `Courier.Application`: nothing in the suite runs a release, and the
  # symptom is a single log line —
  #
  #     Configuration :server was not enabled for CourierWeb.ErrorEndpoint,
  #     http/https services won't start
  #
  # — which reads like a notice and leaves the relay silently unreachable. It is
  # better than a boot crash and worse than a boot failure, which is the worst
  # combination to debug from a container log.
  config :courier, CourierWeb.ErrorEndpoint, server: true
end

config :courier, CourierWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# The From address of every transactional email is deployment configuration:
# an operator sets MAIL_FROM / MAIL_FROM_NAME and redeploys, nobody commits a
# changed address. Subjects stay in config/config.exs — they are product copy,
# not infrastructure. Reading the address from the environment here (rather than
# in `Courier.Mailers`) is deliberate: runtime.exs runs once at boot.
#
# This block, and the adapter below it, are prod-only on purpose. runtime.exs
# runs in every environment *after* the env-specific files, so anything set
# outside `if config_env() == :prod` here would silently override test.exs — and
# a developer's stray MAIL_FROM would change what `mix test` mails.
if config_env() == :prod do
  mailing = Application.get_env(:courier, :mailing, [])
  {from_name, from_address} = mailing[:from]

  config :courier,
         :mailing,
         Keyword.merge(mailing,
           from:
             {System.get_env("MAIL_FROM_NAME", from_name),
              System.get_env("MAIL_FROM", from_address)}
         )

  # No provider adapter ships in this packet. The Local adapter renders into
  # memory and returns a provider-shaped message id, so a released courier
  # exercises the whole pipeline without mailing anyone; the provider packet
  # replaces this line with the provider adapter and its credentials.
  config :courier, Courier.Mailer, adapter: Swoosh.Adapters.Local

  # The key every webhook signing secret is sealed under (`Courier.SecretBox`).
  # It is required rather than defaulted, because a default would be a key in
  # version control and every deployment that forgot to set one would seal its
  # customers' credentials under it. 32 bytes, base64:
  #
  #     openssl rand -base64 32
  #
  # Rotating it means every stored secret has to be re-sealed under the new key,
  # which is why it is a deployment concern and not a courier feature: see
  # `Courier.SecretBox` for the consequences of losing it.
  config :courier,
         :secret_box_key,
         System.get_env("COURIER_SECRET_BOX_KEY") ||
           raise("""
           environment variable COURIER_SECRET_BOX_KEY is missing.

           It is the 32-byte key every webhook signing secret is sealed under.
           Generate one with: openssl rand -base64 32
           """)
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :courier, Courier.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :courier, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # ---------------------------------------------------------------------------
  # Error reporting and the error relay. Both are read here, out of the
  # environment, and **neither is required** — see the reasoning, because a
  # required-looking omission is the thing that surprises an operator.
  #
  # `COURIER_ERROR_REPORTING_DSN` — courier's **own** failures, to its own relay.
  # Unset, courier does not report its own errors and says nothing at boot; that
  # is a diagnosable state (`ErrorReporting.enabled?/0` is false, and
  # `Courier.ErrorRelay.stats/1` shows `forwarded: 0` with nothing arriving
  # anywhere). It is not required because the error store is an *observability*
  # control, and a courier that refuses to boot because its error store is
  # unreachable has turned a missing integration into an outage — see
  # `Courier.ErrorRelay.Sink.Noop`, which documents the same decision at length.
  #
  # `COURIER_ERROR_RELAY_TOKEN` — the shared secret on the **ingest** surface,
  # and this one **is** required, because with no token the surface has no way to
  # tell a service from anybody else, and a default would be a shared secret in
  # version control that every deployment which forgot to set one would accept
  # error reports from. The same rule as `COURIER_SECRET_BOX_KEY` above, and for
  # the same reason: a default is a key in git.
  #
  # `COURIER_ERROR_SINK_DSN` — the relay's own destination, a GlitchTip DSN. This
  # is a **credential** (it carries the project's public ingest key) and is never
  # logged: `Courier.ErrorRelay.Sink.Req` parses it at boot and every refusal it
  # reports is a symbol. Unset, the relay runs with `Sink.Noop` and counts what it
  # discards, which is the same diagnosable-not-fatal shape as above.
  #
  # `COURIER_RELEASE` and `DEPLOYMENT_ENVIRONMENT` are **not** invented here. The
  # release is the build's own identity and the environment is deployment
  # configuration; an operator sets them, and the same value has to reach the
  # traces, so it is read once and stamped on both. Auto-resolution on deploy
  # (GlitchTip resolves an issue when a release that contains the fix ships) is
  # the reason the release is on the event at all: without it the store has no way
  # to know a crash stopped, and an issue stays open for ever.
  # ---------------------------------------------------------------------------
  error_reporting_dsn = System.get_env("COURIER_ERROR_REPORTING_DSN")
  error_relay_token = System.get_env("COURIER_ERROR_RELAY_TOKEN")
  error_sink_dsn = System.get_env("COURIER_ERROR_SINK_DSN")
  release = System.get_env("COURIER_RELEASE") || "unknown"
  environment_name = System.get_env("DEPLOYMENT_ENVIRONMENT") || "production"

  if error_reporting_dsn do
    config :courier, :error_reporting,
      enabled: true,
      dsn: error_reporting_dsn,
      release: release,
      environment: environment_name

    # The SDK's own configuration, and the DSN is courier's **relay** and not a
    # third party. `before_send` is the second redaction barrier and it is what
    # makes a DSN misconfiguration survivable: see
    # `Courier.ErrorReporting.Filter`, whose moduledoc is the argument.
    config :sentry,
      dsn: error_reporting_dsn,
      environment_name: environment_name,
      release: release,
      before_send: {Courier.ErrorReporting.Filter, :before_send},
      send_default_pii: false,
      request_timeout: 3_000,
      pool_size: 5,
      hackney: [recv_timeout: 3_000]
  end

  if is_nil(error_relay_token) do
    raise """
    environment variable COURIER_ERROR_RELAY_TOKEN is missing.

    It is the shared secret every service presents when it reports an unhandled
    error. Generate one with: openssl rand -hex 32

    Unset, the relay refuses every envelope, which is the safe direction — but a
    deployment that means to run the relay and does not have one is silently
    reporting nothing, so this is refused at boot rather than discovered by an
    operator reading a dashboard.
    """
  end

  config :courier, :error_relay_token, error_relay_token

  config :courier, :error_relay,
    name: Courier.ErrorRelay,
    sink: Courier.ErrorRelay.Sink.Req,
    sink_dsn: error_sink_dsn,
    # A burst of five then one per class per minute. The defaults are small on
    # purpose: Sentry does not sample errors by design, so this is the volume
    # control the SDK deliberately does not provide, and the same numbers are set
    # in each of the three services so one config file describes the fleet.
    burst: 5,
    per_minute: 60,
    capacity: 4_096,
    queue_size: 256

  config :courier, CourierWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :courier, CourierWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :courier, CourierWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
