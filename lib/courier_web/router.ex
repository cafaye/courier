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

  scope "/api", CourierWeb do
    pipe_through :api
  end
end
