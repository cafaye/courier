defmodule Courier.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  # NOTE ON THE SENTRY SDK, AND WHY IT IS NOT A CHILD OF THIS SUPERVISOR
  #
  # `:sentry` is an **OTP application of its own** — the dependency's `mix.exs`
  # declares `mod: {Sentry.Application, []}` — so the release starts it and this
  # supervisor does not. Adding `{Sentry, opts}` to `children/2` below looks
  # correct and is not: `Sentry` is a module with no `child_spec/1`, so the
  # supervisor refuses it and courier dies at boot with "The module Sentry was
  # given as a child to a supervisor but it does not implement child_spec/1".
  #
  # That failure is **release-only**, which is what makes it worth writing down
  # rather than rediscovering: in test the SDK has no DSN, nothing asks it to do
  # anything, and `CourierWeb.ErrorReportingTest` starts it itself when it needs
  # it. The whole suite is green over a supervision tree that cannot boot a
  # release. It surfaced the first time this stack was brought up as a release
  # image, and a release image is the only place courier actually runs.
  #
  # "Off in test" is therefore a fact about `Courier.ErrorReporting.enabled?/0`
  # being false and the SDK having no DSN — nothing is captured and nothing leaves
  # the VM — not about the SDK's process being absent. A vendored application
  # always starts; the question is whether it has anything to send.

  @impl true
  def start(_type, _args) do
    children =
      [
        CourierWeb.Telemetry,
        Courier.Repo,
        {DNSCluster, query: Application.get_env(:courier, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Courier.PubSub},
        # courier's only queue: the outbox relay. It needs the repo, so it comes
        # after it, and in test it runs in `:manual` mode (config/test.exs) —
        # jobs land in the database and nothing executes in the background, which
        # is what keeps the Ecto sandbox usable.
        {Oban, Application.fetch_env!(:courier, Oban)},
        # The error relay: the fleet's single redaction chokepoint for the error
        # path, and the sink to GlitchTip behind it.
        #
        # After `Oban` and before either endpoint, and the order is not
        # incidental. Another service can report an error while the relay is still
        # starting, and that report is a POST arriving at a listener which is not
        # up yet — a dropped envelope, counted by the sender, invisible in courier.
        # Starting the relay first closes the window rather than narrowing it.
        #
        # It needs no database, which is the point: `Courier.ErrorRelay` opens no
        # `Repo` and adds no migration, so the error store is GlitchTip's own
        # Postgres and nothing about a store outage can reach `Courier.Repo`.
        # `CourierWeb.ErrorReportingTest` asserts the migration list is unchanged,
        # because "we added no table" is otherwise a claim that is only true by
        # inspection.
        {Courier.ErrorRelay, relay_child_spec()},
        # To serve requests: the customer API, and then the error endpoint on
        # its own port. See `CourierWeb.ErrorEndpoint` for why the ingest
        # surface is a separate listener rather than a route on the first one.
        #
        # Both after the relay, so a report arriving during startup finds a relay
        # already listening rather than a connection to a closed port.
        CourierWeb.Endpoint,
        CourierWeb.ErrorEndpoint
      ]

    # See https://elixir.hexdocs.pm/Application.html
    # for more information on OTP Applications
    opts = [strategy: :one_for_one, name: Courier.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The relay reads its own options rather than the whole application env, so a
  # test can start one with a recording sink and a different throttle without
  # changing what the running relay was told. `config/runtime.exs` builds the same
  # shape in prod, out of the environment.
  defp relay_child_spec do
    :courier
    |> Application.get_env(:error_relay, [])
    |> Keyword.put_new(:name, Courier.ErrorRelay)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CourierWeb.Endpoint.config_change(changed, removed)
    CourierWeb.ErrorEndpoint.config_change(changed, removed)
    :ok
  end
end
