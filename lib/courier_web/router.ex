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

  # Probes. Deliberately outside /api and outside every other pipeline: they run
  # before routing, auth, and the rest of the platform exist, so they must not
  # depend on any of it. See CourierWeb.HealthController.
  scope "/", CourierWeb do
    pipe_through :api

    get "/healthz", HealthController, :healthz
    get "/readyz", HealthController, :readyz
  end

  # The platform's API, under the version prefix core's conventions require.
  # Notification preferences are the first thing courier is asked about over
  # HTTP; authentication is a later packet, and the absence of it is in the
  # controller's moduledoc rather than hidden here.
  scope "/v1", CourierWeb do
    pipe_through :api

    get "/notification_preferences/:user_id", NotificationPreferencesController, :show
    put "/notification_preferences/:user_id", NotificationPreferencesController, :update
  end

  # Webhook endpoints are the first courier resource that cannot be served
  # unauthenticated: an endpoint's url and signing secret are a way to make
  # courier send signed requests, so the whole scope goes through
  # `CourierWeb.Plugs.Principal`, whose default resolver authenticates nobody.
  # Notification preferences above are deliberately *not* in this scope — changing
  # their authorization is not this packet's business, and the gap is recorded in
  # that controller's moduledoc.
  scope "/v1", CourierWeb do
    pipe_through [:api, :authenticated]

    get "/webhook_endpoints", WebhookEndpointsController, :index
    post "/webhook_endpoints", WebhookEndpointsController, :create
    get "/webhook_endpoints/:id", WebhookEndpointsController, :show
    patch "/webhook_endpoints/:id", WebhookEndpointsController, :update
    delete "/webhook_endpoints/:id", WebhookEndpointsController, :delete
    post "/webhook_endpoints/:id/test", WebhookEndpointsController, :ping
  end

  scope "/api", CourierWeb do
    pipe_through :api
  end
end
