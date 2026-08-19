defmodule BinnacleWeb.GuestJSON do
  # Wire serialization of guests (SPEC-0001 REQ read-only-api).
  #
  # Guest identity on the wire is "vmid@hostKey" (design.md: identity
  # derivation), which is also the /api/guests/{id} path segment.
  #
  # @joestump-agent 08/19/2026 - Initial version for SPEC-0001.

  alias BinnacleWeb.HostJSON

  def guest(guest) do
    %{
      id: "#{guest.vmid}@#{guest.host}",
      vmid: guest.vmid,
      host: guest.host,
      name: guest.name,
      status: guest.status,
      containers: Enum.map(guest.containers, &container/1),
      hardware: HostJSON.hardware(guest.hardware)
    }
  end

  def show(%{guest: guest}) do
    guest(guest)
  end

  defp container(container) do
    %{id: container.id, name: container.name, status: container.status}
  end
end
