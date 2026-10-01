defmodule Courier.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
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
