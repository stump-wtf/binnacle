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
  end

  scope "/", BinnacleWeb do
    pipe_through :browser

    live "/", FleetLive, :overview
    live "/gallery", GalleryLive, :gallery
  end

  # Other scopes may use custom stacks.
  # scope "/api", BinnacleWeb do
  #   pipe_through :api
  # end
end
