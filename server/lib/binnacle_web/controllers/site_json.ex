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
            kind: site.kind,
            status: site.status,
            host_count: length(site.hosts)
          }
        end)
    }
  end

  def show(%{site: site}) do
    %{
      slug: site.slug,
      kind: site.kind,
      status: site.status,
      hosts: Enum.map(site.hosts, &HostJSON.host/1)
    }
  end
end
