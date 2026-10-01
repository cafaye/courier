defmodule Courier.MixProject do
  use Mix.Project

  def project do
    [
      app: :courier,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # The coverage tool, named here rather than discovered at run time.
      # `mix test --cover` writes `cover/` and enforces nothing; this is what
      # makes `mix coveralls --minimum-coverage` work, which is the command both
      # this repository's CI gate and kit's shared Elixir job run.
      test_coverage: [tool: ExCoveralls],
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Courier.Application, []},
      # `:opentelemetry` is here because the SDK is an OTP application started by
      # the application controller, and it has to be started before
      # `Courier.Application.start/2` for its configuration (in
      # `config/runtime.exs`) to take effect. Adding it to `applications` instead
      # would start it after courier's own supervisor and the exporter would never
      # be built.
      extra_applications: [:logger, :runtime_tools, :opentelemetry]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.15"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      # OpenTelemetry. The trace SDK and the OTLP exporter, and the reason each is
      # named here is in lib/courier/telemetry.ex: without them courier has no way
      # to emit a span at all, and kit's collector has nothing to redact.
      #
      # `only: [:dev, :test, :prod]` is deliberately not a restriction — it is
      # every environment courier has. The exporter is a real dependency in every
      # one because `<SERVICE>_OTEL_ENDPOINT` is ON BY DEFAULT (core D16): a
      # developer running `mix phx.server` exports into the collector that ships
      # with the stack, and that is the whole of "a deployer gets traces without
      # assembling them". Gating the exporter to :prod would make the default a
      # no-op everywhere it is actually used, which is backwards.
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.11"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:swoosh, "~> 1.28"},
      {:oban, "~> 2.24"},
      # Webhook delivery needs an HTTP client. Req is the one this repository's own
      # generated rules name as preferred ("Use the already included and available
      # `:req` (`Req`) library for HTTP requests, avoid `:httpoison`, `:tesla`, and
      # `:httpc`"), so the webhook pipeline uses it rather than `:httpc` from OTP or
      # a second client library.
      {:req, "~> 0.5"},
      # `mix coveralls` — the coverage gate kit's shared Elixir job runs, and the
      # one this repository's own CI job runs. Two things about it are load
      # bearing and neither is guessable:
      #
      #   - The task ships in **excoveralls**. The hex package named `coveralls`
      #     is the Erlang one and has no Mix task at all, so declaring that
      #     leaves the gate dying on "the task coveralls could not be found".
      #   - `dev` is in the list on purpose. The job fetches dependencies with a
      #     plain `mix deps.get` (development) and then runs `mix coveralls`,
      #     which is `@preferred_cli_env :test`. A dep that is only in `:test` is
      #     never fetched by the first command, and the second one fails on a
      #     missing dependency rather than on a coverage number.
      #
      # `runtime: false`, and no `:prod`, so a measurement tool is neither
      # started nor shipped in the release.
      {:excoveralls, "~> 0.18.5", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
