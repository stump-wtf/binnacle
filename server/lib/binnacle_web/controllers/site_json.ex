defmodule BinnacleWeb.SiteJSON do
  # Wire serialization of sites (SPEC-0001 REQ read-only-api).
  #
  # Renders the fleet model, never the config: no credentials can appear
  # here because none exist in the snapshot structs.
  #
  # @joestump-agent 08/19/2026 - Initial version for SPEC-0001.

  alias BinnacleWeb.HostJSON

  def index(%{sites: sites}) do
    %{
      sites:
        Enum.map(sites, fn site ->
          %{
            slug: site.slug,
            name: site.name,
            kind: site.kind,
            status: site.status,
            host_count: length(site.hosts),
            network: network(site.network),
            drift: drift(site.drift)
          }
        end)
    }
  end

  def show(%{site: site}) do
    %{
      slug: site.slug,
      name: site.name,
      kind: site.kind,
      status: site.status,
      network: network(site.network),
      drift: drift(site.drift),
      hosts: Enum.map(site.hosts, &HostJSON.host/1)
    }
  end

  # nil means no gateway is configured for this site, which is a different
  # answer from a gateway that stopped answering — the latter arrives as
  # reachable: false with its reason.
  defp network(nil), do: nil

  defp network(net) do
    %{
      reachable: net.reachable,
      reason: net.reason,
      at: net.at,
      gateway: device(net.gateway),
      devices: Enum.map(net.devices, &device/1)
    }
  end

  defp device(nil), do: nil

  defp device(d) do
    %{
      mac: d.mac,
      name: d.name,
      model: d.model,
      kind: d.kind,
      status: d.status,
      adopted: d.adopted,
      version: d.version,
      uptime: d.uptime
    }
  end

  defp drift(nil), do: []

  defp drift(entries) do
    Enum.map(entries, fn d ->
      %{
        kind: d.kind,
        detail: d.detail,
        observed: d.observed,
        site: d.site
      }
    end)
  end
end
