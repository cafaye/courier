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
end

config :courier, CourierWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# ---------------------------------------------------------------------------
# OPENTELEMETRY. In every environment, and that is the point.
#
# A developer running `mix phx.server` exports into the collector that ships with
# the stack, and a deployer gets traces without assembling anything. Gating this
# to :prod would make the default a no-op everywhere it is actually used, which is
# backwards.
#
# The RULES are in `Courier.Telemetry` and this is four lines that call into it —
# not a second copy of them. The Erlang SDK is configured through the application
# environment and started by the application controller, which runs before
# `Courier.Application.start/2`, so there is no code path that could set this
# earlier; keeping the logic in a module is what makes it testable at all.
#
# `<SERVICE>_OTEL_ENDPOINT` is the only contract (core D16). Unset, it is the
# collector that ships with the stack. Set it to anything speaking OTLP and
# courier goes there instead — bring-your-own is a supported deployment, not a
# degraded mode.
#
# NOT IN TEST, and the guard is load-bearing rather than fussy. `runtime.exs` runs
# AFTER every environment's config file, including `test.exs` — so an unguarded
# line here would replace the suite's in-memory exporter with a real OTLP one.
# Every redaction test in this repository asserts the ABSENCE of a canary from the
# exported spans, and a real exporter in a suite with no collector exports
# nothing: all of them would go green, in about a second, having proved nothing.
# A guard whose absence produces a green suite is the worst kind of guard to
# leave to a reader.
if config_env() != :test do
  config :opentelemetry, Courier.Telemetry.sdk_config()
end

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

  # THE PROVIDER ADAPTER, and the refusal is the point.
  #
  # This line used to be:
  #
  #     config :courier, Courier.Mailer, adapter: Swoosh.Adapters.Local
  #
  # which is the failure this packet exists to end. `Local` renders a message
  # into memory and returns a provider-shaped id without opening a socket, so a
  # released courier accepted every send, recorded an outbox row for each one,
  # published a `delivered` event, and mailed nobody. No error and no warning —
  # the worst failure a paid product can have, because it looks like it works.
  #
  # What replaced it is `Courier.MailerAdapter.adapter!/1`, which reads
  # COURIER_MAIL_ADAPTER and the COURIER_SMTP_* variables and RAISES if they are
  # unset, if they name an adapter courier does not ship, or if they name one
  # that cannot deliver. A raise here stops the boot. `Courier.Application`
  # re-checks the resolved adapter as a second, independent gate.
  #
  # Nothing is defaulted. An adapter with a default is an adapter that is wrong
  # for exactly the deployments nobody is watching, and a required setting is the
  # only version of this that cannot be forgotten.
  #
  # Bound to a variable and called ONCE: `adapter!/1` raises on a misconfigured
  # deployment, and calling it twice would mean a boot that raised after the
  # config had already been applied — leaving the process half-configured rather
  # than cleanly stopped.
  mailer_adapter = Courier.MailerAdapter.adapter!(:prod)

  config :courier, Courier.Mailer, mailer_adapter

  # The one startup line an operator reads to confirm which relay courier is
  # pointed at. It names the host, the port and whether auth is on — never the
  # username and never the password, because at SMTP a "username" is very often
  # the API key. See `Courier.MailerAdapter.describe/1` and the credential tests
  # that assert the absence rather than trusting this comment.
  require Logger

  Logger.info("mailer: #{Courier.MailerAdapter.describe(mailer_adapter)}")

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
