defmodule Courier.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The SECOND gate on the provider adapter, and it is deliberately not a
    # re-run of the first.
    #
    # `config/runtime.exs` resolves the adapter from the environment and raises
    # on an unset or silent one. That gate runs first and, in this tree, is
    # sufficient on its own — being honest about that is the point, because a
    # comment claiming this gate catches more than it does would be the same
    # sin as an overclaimed test.
    #
    # What it adds is that it reads the EFFECTIVE configuration
    # (`Application.get_env/2`) rather than the environment. So it is no longer
    # checking an intention, it is checking what courier will actually send
    # through, and it holds when the first gate is bypassed or removed:
    #
    #   * `config/runtime.exs` edited to name `Swoosh.Adapters.Local` directly —
    #     one line, no environment variable, and the previous state of this
    #     repository was exactly that;
    #   * any future path that configures the mailer without going through
    #     `Courier.MailerAdapter` — a release overlay, a runtime config hook, a
    #     generator. This gate does not care where the value came from.
    #
    # Re-checking the environment twice would catch nothing this does not.
    Courier.MailerAdapter.verify_boot!()

    # One line, and only ever on the DISABLED path. It is here rather than in
    # `config/runtime.exs` because configuration cannot log into the store an
    # operator reads. See Courier.Telemetry for the contract this reports on.
    Courier.Telemetry.log_startup()

    children = [
      # The request-span instrumentation. A child rather than an endpoint plug
      # because it owns a `:telemetry` handler for the exception path, and a
      # handler attached from a plug's `init/1` is re-attached on every reload.
      Courier.Telemetry,
      Courier.Repo,
      {DNSCluster, query: Application.get_env(:courier, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Courier.PubSub},
      # courier's only queue: the outbox relay. It needs the repo, so it comes
      # after it, and in test it runs in `:manual` mode (config/test.exs) —
      # jobs land in the database and nothing executes in the background, which
      # is what keeps the Ecto sandbox usable.
      {Oban, Application.fetch_env!(:courier, Oban)},
      # Start a worker by calling: Courier.Worker.start_link(arg)
      # {Courier.Worker, arg},
      # Start to serve requests, typically the last entry
      CourierWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Courier.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CourierWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
