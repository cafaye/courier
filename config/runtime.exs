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
