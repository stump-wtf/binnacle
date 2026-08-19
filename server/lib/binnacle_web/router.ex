defmodule BinnacleWeb.Router do
  use BinnacleWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BinnacleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug BinnacleWeb.Plugs.RateLimit
    plug BinnacleWeb.Plugs.ApiAuth
  end

  scope "/", BinnacleWeb do
    pipe_through :browser

    live "/", FleetLive, :overview
    live "/gallery", GalleryLive, :gallery
  end

  # Read-only taxonomy API (SPEC-0001). GET only; anything else on /api
  # answers 405 via the catch-all below.
  scope "/api", BinnacleWeb do
    pipe_through :api

    get "/sites", SiteController, :index
    get "/sites/:slug", SiteController, :show
    get "/hosts/:key", HostController, :show
    get "/guests/:id", GuestController, :show

    match :*, "/*_path", SiteController, :method_not_allowed
  end

  # Public liveness probe — deliberately outside the :api pipeline.
  get "/healthz", BinnacleWeb.HealthController, :show
end
