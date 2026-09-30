defmodule CourierWeb.Router do
  use CourierWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
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

  scope "/api", CourierWeb do
    pipe_through :api
  end
end
