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

  describe "the messages surface" do
    alias CourierWeb.MessagesController

    test "POST /v1/messages resolves to CourierWeb.MessagesController.create/2" do
      assert %{plug: MessagesController, plug_opts: :create, route: "/v1/messages"} =
               Phoenix.Router.route_info(Router, "POST", "/v1/messages", "")
    end

    test "it is behind the authenticated pipeline, and that is not a formality" do
      # An unauthenticated POST to a mail egress is an open relay. This is the one
      # route in courier where that is true rather than theoretical, so the pipeline
      # is asserted here rather than left to the controller's own tests — which go
      # through the same router and would agree with a router that did not have it.
      assert %{pipe_through: pipelines} =
               Phoenix.Router.route_info(Router, "POST", "/v1/messages", "")

      assert :authenticated in pipelines, "POST /v1/messages must be behind authentication"
    end

    test "it is behind the idempotency pipeline, because a send is not idempotent" do
      # A caller that timed out and retried without the header mails somebody
      # twice, and no row afterwards can tell the two messages apart.
      assert %{pipe_through: pipelines} =
               Phoenix.Router.route_info(Router, "POST", "/v1/messages", "")

      assert :idempotent in pipelines
    end

    test "it does not answer write methods other than POST" do
      for method <- ~w(GET PUT PATCH DELETE) do
        assert :error == Phoenix.Router.route_info(Router, method, "/v1/messages", "")
      end
    end
  end

  describe "the webhook endpoints surface" do
    alias CourierWeb.WebhookEndpointsController

    @routes [
      {"GET", "/v1/webhook_endpoints", :index},
      {"POST", "/v1/webhook_endpoints", :create},
      {"GET", "/v1/webhook_endpoints/8f3c2b1a-0000-4000-8000-000000000001", :show},
      {"PATCH", "/v1/webhook_endpoints/8f3c2b1a-0000-4000-8000-000000000001", :update},
      {"DELETE", "/v1/webhook_endpoints/8f3c2b1a-0000-4000-8000-000000000001", :delete},
      {"POST", "/v1/webhook_endpoints/8f3c2b1a-0000-4000-8000-000000000001/test", :ping}
    ]

    test "every action resolves to CourierWeb.WebhookEndpointsController" do
      for {method, path, action} <- @routes do
        assert %{plug: WebhookEndpointsController, plug_opts: ^action} =
                 Phoenix.Router.route_info(Router, method, path, "")
      end
    end

    test "every action is behind the authenticated pipeline" do
      # Not one of them: a single action outside the pipeline is an endpoint that
      # serves whoever asks, and the controller's own matrix would not catch it,
      # because that matrix goes through the same router.
      for {method, path, _action} <- @routes do
        assert %{pipe_through: pipelines} = Phoenix.Router.route_info(Router, method, path, "")

        assert :authenticated in pipelines, "#{method} #{path} must be behind authentication"
      end
    end

    test "notification preferences are behind it too, on both verbs" do
      # The same claim about the same pipeline, asserted over the resource that
      # used to be the exception. It lives beside the webhook assertion rather
      # than in a describe of its own because there is nothing left to say about
      # it that is not said there: a route courier does not authenticate is a
      # route that serves whoever asks, and the two surfaces now differ only in
      # what they hold.
      for verb <- ~w(GET PUT) do
        assert %{pipe_through: pipelines} =
                 Phoenix.Router.route_info(Router, verb, "/v1/notification_preferences/abc", "")

        assert :authenticated in pipelines,
               "#{verb} notification preferences must be authenticated"
      end
    end

    test "no action answers a method it does not declare" do
      # `POST /v1/webhook_endpoints` is create and nothing else. A `PUT` on the
      # same path would be a second way to do the same thing with different
      # semantics, which is what core's conventions are there to prevent.
      assert served_on("/v1/webhook_endpoints") == ["GET", "POST"]
      assert served_on("/v1/webhook_endpoints/:id") == ["DELETE", "GET", "PATCH"]
      assert served_on("/v1/webhook_endpoints/:id/test") == ["POST"]
    end

    test "the path is the plural noun core's conventions ask for, under /v1" do
      # core/docs/openapi-conventions.md: "Path under `/v1`, no trailing slash,
      # plural nouns, kebab-case for multi-word."
      for {_method, path, _action} <- @routes do
        assert String.starts_with?(path, "/v1/webhook_endpoint")
        refute String.ends_with?(path, "/")
      end
    end
  end

  # Which methods the router answers for a route pattern, discovered rather than
  # declared, so a route serving more than it documents shows up here. The pattern
  # has to be the router's own — `route_info/4` matches the route as written, not
  # a path that would reach it.
  defp served_on(route) do
    ~w(GET POST PUT PATCH DELETE)
    |> Enum.filter(&match?(%{route: ^route}, Phoenix.Router.route_info(Router, &1, route, "")))
    |> Enum.sort()
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
