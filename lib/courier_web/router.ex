defmodule CourierWeb.Router do
  use CourierWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
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

  scope "/api", CourierWeb do
    pipe_through :api
  end
end
