defmodule Binnacle.Fleet.Discovery do
  # Live fleet discovery from Proxmox and UniFi APIs.
  #
  # Replaces the static baseline.json with API-driven topology:
  # - Sites come from the UniFi Controller (/api/self/sites)
  # - Hosts come from each Proxmox hypervisor's node list (/api2/json/nodes)
  # - Guests come from each Proxmox hypervisor's qemu + lxc lists
  #
  # The site→host mapping is NOT discoverable from either API — it comes from
  # config (FLEET_SITE_MAP env var). Unmapped hosts are assigned to a default
  # site.
  #
  # When no API credentials are configured, returns nil and the Fleet falls
  # back to baseline.json.

  require Logger

  alias Binnacle.Fleet.Model.{Guest, Host, Site}
  alias Binnacle.Fleet.Proxmox.Client, as: PveClient
  alias Binnacle.Fleet.Unifi.Client, as: UnifiClient

  @type proxmox_node :: %{name: String.t(), url: String.t(), token: String.t()}
  @type unifi_config :: %{url: String.t(), api_key: String.t()}
  @type site_kind_map :: %{String.t() => :home | :airbnb}

  @doc """
  Discover the fleet topology from live APIs.

  Returns `{:ok, %{sites: [Site], hosts: [Host], guests: [Guest]}}` when at
  least one API source is configured and reachable, or `{:error, reason}` on
  total failure. Returns `nil` when no API credentials are configured at all
  (caller should fall back to baseline.json).
  """
  @spec discover(keyword()) ::
          {:ok, %{sites: [Site.t()], hosts: [Host.t()], guests: [Guest.t()]}}
          | {:error, String.t()}
          | nil
  def discover(opts \\ []) do
    proxmox_nodes = Keyword.get(opts, :proxmox_nodes, [])
    unifi = Keyword.get(opts, :unifi)
    site_kinds = Keyword.get(opts, :site_kinds, %{})
    site_map = Keyword.get(opts, :site_map, %{})

    has_proxmox = proxmox_nodes != []
    has_unifi = unifi != nil

    cond do
      not has_proxmox and not has_unifi ->
        nil

      true ->
        sites_result =
          if has_unifi, do: UnifiClient.fetch_sites(unifi.url, unifi.api_key), else: {:ok, []}

        hosts_guests = discover_proxmox(proxmox_nodes)

        case sites_result do
          {:ok, discovered_sites} ->
            # Total-outage guard: zero sites and zero reachable hypervisors
            # means nothing answered — fall back to baseline rather than
            # wiping the topology.
            if discovered_sites == [] and hosts_guests.ok == 0 do
              {:error,
               "no API source produced topology (#{length(proxmox_nodes)} Proxmox nodes configured, all failed or none set; UniFi returned no sites)"}
            else
              sites = apply_site_kinds(discovered_sites, site_kinds)
              hosts = assign_hosts_to_sites(hosts_guests.hosts, site_map, sites)
              {:ok, %{sites: sites, hosts: hosts, guests: hosts_guests.guests}}
            end

          {:error, reason} ->
            # Total-outage guard: credentials are configured but nothing
            # answered. An empty {:ok, _} here would wipe the topology; the
            # Fleet falls back to baseline.json instead.
            if hosts_guests.ok == 0 do
              {:error, "all configured API sources failed (UniFi: #{reason})"}
            else
              Logger.warning("UniFi site discovery failed: #{reason}")
              sites = fallback_sites_from_hosts(hosts_guests.hosts, site_map, site_kinds)
              hosts = assign_hosts_to_sites(hosts_guests.hosts, site_map, sites)
              {:ok, %{sites: sites, hosts: hosts, guests: hosts_guests.guests}}
            end
        end
    end
  end

  defp discover_proxmox(nodes) do
    results =
      Enum.map(nodes, fn node ->
        case PveClient.fetch(node.url, node.token) do
          {:ok, %{guests: guests, node_status: _status}} ->
            host = %Host{
              key: node.name,
              site: "default",
              dial_ip: nil,
              guests: [],
              hardware: [],
              status: :unknown,
              history: []
            }

            tagged_guests = Enum.map(guests, &%{&1 | host: node.name})
            {:ok, host, tagged_guests}

          {:error, reason} ->
            Logger.warning("Proxmox discovery failed for #{node.name}: #{reason}")
            {:error, node.name, reason}
        end
      end)

    hosts = for {:ok, host, _guests} <- results, do: host
    guests = for {:ok, _host, guest_list} <- results, guest <- guest_list, do: guest

    %{hosts: hosts, guests: guests, ok: length(hosts)}
  end

  defp apply_site_kinds(sites, kinds) when map_size(kinds) == 0, do: sites

  defp apply_site_kinds(sites, kinds) do
    Enum.map(sites, fn site ->
      case Map.get(kinds, site.slug) do
        nil -> site
        kind -> %{site | kind: kind}
      end
    end)
  end

  defp assign_hosts_to_sites(hosts, site_map, sites) do
    site_slugs = MapSet.new(sites, & &1.slug)

    Enum.map(hosts, fn host ->
      mapped_site = Map.get(site_map, host.key, "default")

      site =
        cond do
          MapSet.member?(site_slugs, mapped_site) -> mapped_site
          sites == [] -> "default"
          true -> List.first(sites).slug || "default"
        end

      %{host | site: site}
    end)
  end

  defp fallback_sites_from_hosts(hosts, site_map, site_kinds) do
    slugs =
      hosts
      |> Enum.map(fn h -> Map.get(site_map, h.key, "default") end)
      |> Enum.uniq()

    Enum.map(slugs, fn slug ->
      kind = Map.get(site_kinds, slug, :home)
      %Site{slug: slug, kind: kind, hosts: []}
    end)
  end
end
