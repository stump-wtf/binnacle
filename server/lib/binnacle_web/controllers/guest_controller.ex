defmodule BinnacleWeb.GuestController do
  # /api/guests/{id} (SPEC-0001 REQ read-only-api).
  #
  # `id` is "vmid@hostKey" — the derived identity from design.md. A bare vmid
  # is accepted when it is unambiguous, so operators can type either.
  #
  # @joestump-agent 08/19/2026 - Initial version for SPEC-0001.

  use BinnacleWeb, :controller

  alias Binnacle.Fleet

  action_fallback BinnacleWeb.FallbackController

  def show(conn, %{"id" => id}) do
    case find_guest(Fleet.snapshot(), id) do
      nil -> {:error, :not_found}
      guest -> render(conn, :show, guest: guest)
    end
  end

  defp find_guest(sites, id) do
    guests = sites |> Enum.flat_map(& &1.hosts) |> Enum.flat_map(& &1.guests)

    case Integer.parse(id) do
      {vmid, ""} ->
        case Enum.filter(guests, &(&1.vmid == vmid)) do
          [guest] -> guest
          [_ | _] -> guest_by_identity(guests, id)
          [] -> nil
        end

      _ ->
        guest_by_identity(guests, id)
    end
  end

  defp guest_by_identity(guests, id) do
    Enum.find(guests, &("#{&1.vmid}@#{&1.host}" == id))
  end
end
