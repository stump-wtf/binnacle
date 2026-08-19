defmodule BinnacleWeb.HostController do
  # /api/hosts/{key} (SPEC-0001 REQ read-only-api).
  #
  # @joestump-agent 08/19/2026 - Initial version for SPEC-0001.

  use BinnacleWeb, :controller

  alias Binnacle.Fleet

  action_fallback BinnacleWeb.FallbackController

  def show(conn, %{"key" => key}) do
    snapshot = Fleet.snapshot()

    case find_host(snapshot, key) do
      nil -> {:error, :not_found}
      host -> render(conn, :show, host: host)
    end
  end

  defp find_host(sites, key) do
    sites
    |> Enum.flat_map(& &1.hosts)
    |> Enum.find(&(&1.key == key))
  end
end
