defmodule CourierWeb.RouterTest do
  @moduledoc """
  The probes are infrastructure endpoints: orchestrators hit them before any
  traffic, from outside `/api`, and they must not drift onto a different
  pipeline, format, or controller. Asserting the resolved route — not just the
  path — is what pins the controller, the action, and the scope.
  """

  use ExUnit.Case, async: true

  alias CourierWeb.HealthController
  alias CourierWeb.Router

  test "GET /healthz resolves to CourierWeb.HealthController.healthz/2" do
    assert %{plug: HealthController, plug_opts: :healthz, route: "/healthz"} =
             Phoenix.Router.route_info(Router, "GET", "/healthz", "")
  end

  test "GET /readyz resolves to CourierWeb.HealthController.readyz/2" do
    assert %{plug: HealthController, plug_opts: :readyz, route: "/readyz"} =
             Phoenix.Router.route_info(Router, "GET", "/readyz", "")
  end

  test "the probes are served at the root, outside the /api scope" do
    for path <- ["/healthz", "/readyz"] do
      assert %{route: ^path} = Phoenix.Router.route_info(Router, "GET", path, "")
      refute String.starts_with?(path, "/api")
    end
  end

  test "the probes do not answer write methods" do
    for method <- ~w(POST PUT PATCH DELETE) do
      assert :error == Phoenix.Router.route_info(Router, method, "/healthz", "")
      assert :error == Phoenix.Router.route_info(Router, method, "/readyz", "")
    end
  end

  describe "in the production environment" do
    setup do
      # config/prod.exs is compile-time configuration, so it is not in the test
      # environment's config. Read it back the way a release would.
      config = Config.Reader.read!("config/prod.exs", env: :prod)
      {:ok, force_ssl: config[:courier][CourierWeb.Endpoint][:force_ssl]}
    end

    test "the probes are exempt from the SSL redirect", %{force_ssl: force_ssl} do
      # Otherwise a load balancer or orchestrator probing a released courier gets
      # a 301 to https and reads it as a dead service.
      assert ["/healthz", "/readyz"] == force_ssl[:exclude][:paths]
    end
  end
end
