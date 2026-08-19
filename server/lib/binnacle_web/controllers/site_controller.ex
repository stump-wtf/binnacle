defmodule BinnacleWeb.SiteController do
  # /api/sites and /api/sites/{slug} (SPEC-0001 REQ read-only-api).
  #
  # @joestump-agent 08/19/2026 - Initial version for SPEC-0001.

  use BinnacleWeb, :controller

  alias Binnacle.Fleet

  action_fallback BinnacleWeb.FallbackController

  def index(conn, _params) do
    render(conn, :index, sites: Fleet.snapshot())
  end

  def show(conn, %{"slug" => slug}) do
    case Enum.find(Fleet.snapshot(), &(&1.slug == slug)) do
      nil -> {:error, :not_found}
      site -> render(conn, :show, site: site)
    end
  end

  # Non-GET on /api/* is always 405 (SPEC-0001: data endpoints are read-only).
  def method_not_allowed(_conn, _params) do
    {:error, :method_not_allowed}
  end
end
