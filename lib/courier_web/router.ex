defmodule CourierWeb.Router do
  use CourierWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The provider surface's pipeline, and it is one line long because the
  # authentication is the *body's* signature rather than a plug: there is no
  # `CourierWeb.Plugs.Signed` to put here, because the verifier needs the raw
  # bytes and a plug that has read the body cannot hand them back unchanged.
  #
  # `:api` is **not** folded in — the scope lists it beside this one — so the 406
  # every operation in `openapi.yaml` declares comes from the same pipeline it
  # comes from everywhere else, rather than from a second `:accepts` that would
  # have to be kept in step with the first.
  #
  # It names the provider rather than the controller inferring it from its own
  # route, so a second provider is a second scope entry and a second secret with
  # nothing in this file that has to change. Deliberately **not** including
  # `:authenticated` or `:idempotent` — see the scope's comment and
  # `Courier.InboundReports`'s moduledoc, which is where the reasoning for the
  # second of those lives.
  pipeline :inbound do
    plug :inbound_provider
  end

  # Everything that needs to know who is asking. The plug refuses an anonymous
  # caller outright rather than defaulting to an account — see its moduledoc for
  # why a seam that authenticates nobody is the right default until identity's
  # JWT verifier lands.
  pipeline :authenticated do
    plug CourierWeb.Plugs.Principal
  end

  # `Idempotency-Key`, on the mutating POSTs and nothing else. Core requires it on
  # a POST that can be retried safely, which is these two and not the other six
  # actions: `GET` and `DELETE` are idempotent by HTTP's definition, `PATCH` here
  # is a partial update whose repeat is already the same row, and `PUT` on
  # notification preferences stores the state it is given rather than accumulating
  # deltas.
  #
  # After `:authenticated` on purpose — the key is scoped to the principal, so it
  # cannot be claimed before courier knows who is asking.
  pipeline :idempotent do
    plug CourierWeb.Plugs.Idempotency
  end

  # The paths whose request bodies have to reach a controller UNPARSED, and the
  # reason this list is here rather than written into
  # `CourierWeb.Plugs.ParseBody`: a path written into the plug is a path nothing
  # in this module knows about, so a rename leaves the parser reading a body whose
  # signature covered bytes that have since been re-encoded — and a JSON round trip
  # is byte-identical for most payloads, so the verifier that then refuses is the
  # only thing standing between a rename and a broken inbound surface.
  #
  # `test/courier_web/router_test.exs` asserts every path here is a route this
  # router serves, which is what stops the list going stale.
  @signed_body_paths ["/inbound/resend"]

  @doc """
  Whether a request to `path` is a signed inbound body courier must not decode.

  Trailing-slash insensitive, because `Phoenix.Router` matches `/inbound/resend/`
  to the same route: a check that only knew the spelling without the slash would
  parse exactly the request a copy-pasted URL produces.
  """
  @spec signed_body?(term()) :: boolean()
  def signed_body?(path) when is_binary(path) do
    case String.trim_trailing(path, "/") do
      "" -> false
      trimmed -> trimmed in @signed_body_paths
    end
  end

  def signed_body?(_other), do: false

  @doc "The paths `signed_body?/1` answers for, so a test can hold them to the router."
  @spec signed_body_paths() :: [String.t()]
  def signed_body_paths, do: @signed_body_paths

  # Probes. Deliberately outside /api and outside every other pipeline: they run
  # before routing, auth, and the rest of the platform exist, so they must not
  # depend on any of it. See CourierWeb.HealthController.
  scope "/", CourierWeb do
    pipe_through :api

    get "/healthz", HealthController, :healthz
    get "/readyz", HealthController, :readyz
  end

  # Everything a caller must be an authenticated caller for.
  #
  # Webhook endpoints were the first of these, because an endpoint's url and
  # signing secret are a way to make courier send signed requests and a list
  # endpoint with no authentication is a way to enumerate them. Notification
  # preferences joined them for the same reason at a smaller scale: a `user_id` in
  # a path is a string anybody can write, so a surface that reads and writes by
  # one is a surface where any caller can read and overwrite any other tenant's
  # answers by guessing an id.
  #
  # Both live in one scope because there is nothing left to distinguish them: the
  # refusal is the same plug's refusal and the same `401`, and a caller that has
  # to handle two kinds of 401 is a caller that will handle one of them wrongly.
  #
  # `CourierWeb.Plugs.Principal`, whose default resolver authenticates nobody —
  # so a courier deployed without identity's JWT verifier locks these rather than
  # serving them.
  scope "/v1", CourierWeb do
    pipe_through [:api, :authenticated]

    get "/notification_preferences/:user_id", NotificationPreferencesController, :show
    put "/notification_preferences/:user_id", NotificationPreferencesController, :update

    get "/webhook_endpoints", WebhookEndpointsController, :index
    get "/webhook_endpoints/:id", WebhookEndpointsController, :show
    patch "/webhook_endpoints/:id", WebhookEndpointsController, :update
    delete "/webhook_endpoints/:id", WebhookEndpointsController, :delete
  end

  # The same resource, on the two POSTs. A separate scope rather than one
  # pipeline over all eight, because the header is for a POST that can be retried
  # and putting it on the other six would claim an idempotency courier does not
  # provide — `GET` and `DELETE` are idempotent by HTTP's definition, `PATCH`
  # here is a partial update whose repeat is already the same row, and `PUT` is
  # idempotent by construction because it stores the state it is given rather than
  # accumulating deltas. `test/courier_web/router_test.exs` asserts
  # `:authenticated` on every action, and this keeps that true while adding the
  # second pipeline.
  scope "/v1", CourierWeb do
    pipe_through [:api, :authenticated, :idempotent]

    post "/webhook_endpoints", WebhookEndpointsController, :create
    post "/webhook_endpoints/:id/test", WebhookEndpointsController, :ping

    # courier's only door into its send path, and the reason this scope exists in
    # the shape it does. It is behind `:idempotent` for the reason every other POST
    # here is: a send is not idempotent by HTTP's definition, so a caller that
    # timed out would otherwise mail somebody twice, and it is behind
    # `:authenticated` because an unauthenticated POST to a mail egress is an open
    # relay.
    post "/messages", MessagesController, :create
  end

  # The provider surface, and it is OUTSIDE `/v1` on purpose. `/v1` is courier's
  # versioned contract with a tenant and every operation under it is authenticated
  # with a bearer token; `PLAN.md` MD6 has the platform generating client SDKs
  # from `openapi.yaml`, and an operation filed under `/v1` that cannot take a
  # bearer token is a method a generated client will call wrongly.
  #
  # It is in a scope of its own with no `pipe_through :authenticated`, and both
  # halves of that are load-bearing:
  #
  #   * **A provider is not a tenant.** Resend signs its webhook with Svix and
  #     sends no token. Behind `CourierWeb.Plugs.Principal` every delivery would be
  #     a 401.
  #   * **An unauthenticated `POST` that records suppressions is a denial of
  #     service on the whole product**, delivered by the feature meant to prevent
  #     it. So this route authenticates with a SIGNATURE instead —
  #     `Courier.Inbound.Signature`, verified before the body is parsed — which is
  #     core's own rule for an inbound webhook: "Inbound webhooks are not
  #     JWT-authenticated: they are signed, per the sender's convention, and the
  #     receiver checks the signature before parsing."
  #
  # `:api` and nothing else: the `:accepts` plug is the 406 every operation in
  # `openapi.yaml` declares, and the other two things this route needs — the body
  # left unparsed and a bound on how much of it courier will buffer — are decisions
  # about one request rather than about a class of requests, so they live in the
  # action next to the order they happen in.
  #
  # The provider is in the PATH, so a second provider is a second path rather than
  # a discriminator in a body: a body is untrusted input until a signature has
  # verified it, and the path is chosen by whoever configured the webhook.
  scope "/inbound", CourierWeb do
    pipe_through [:api, :inbound]

    post "/resend", InboundController, :create
  end

  scope "/api", CourierWeb do
    pipe_through :api
  end

  # The provider a signed inbound request is from, as an assign.
  #
  # The route is `/inbound/resend`, so the provider is in the PATH — which is
  # where a webhook URL is configured, in the provider's own dashboard, and a
  # path segment is therefore a thing courier does not get to disagree with. A
  # body naming the provider would be a caller choosing which vocabulary its own
  # payload is read with, which is the wrong direction for a field the sender
  # controls.
  #
  # It is an assign rather than a `Reports.secret(conn)` inside the controller so
  # that the pipeline reads as the whole of what this surface does before the
  # action runs, and so a test can put a provider there without a route.
  defp inbound_provider(conn, _opts) do
    assign(conn, :inbound_provider, provider_for(conn.request_path))
  end

  defp provider_for(path) when is_binary(path) do
    path
    |> String.split("/")
    |> List.last()
    |> case do
      "resend" -> "resend"
      _unknown -> nil
    end
  end
end
