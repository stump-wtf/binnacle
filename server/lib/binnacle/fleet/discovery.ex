defmodule Binnacle.Fleet.Discovery do
  # Config drift: what the APIs report, against what the baseline declares.
  #
  # Governing: ADR-0002 (fleet taxonomy), SPEC-0001 REQ "Discovery Does Not
  # Invent Topology" — "Discovery MUST NOT create Sites or Hosts. Entities
  # observed outside configured topology MUST be surfaced as config drift."
  #
  # This module used to do the opposite. `discover/1` built a topology FROM
  # the APIs and `Binnacle.Fleet.init/1` took it wholesale, so a successful
  # discovery replaced every declared site and host. Two things were wrong
  # with that, and the second is why it can never be repaired in place:
  #
  #   1. Hosts came only from the Proxmox node lists, so every standalone
  #      Docker host — most of the fleet — vanished the moment discovery
  #      succeeded.
  #
  #   2. Sites came from UniFi. Each property runs its OWN controller, and
  #      every one of them reports a single site named "default". Four
  #      properties do not produce four sites; they produce four answers of
  #      "default", which collapse into one. The API cannot tell you which
  #      building it is standing in, because nothing in it knows.
  #
  # So topology is declared, and discovery's job is to report where the world
  # disagrees with the declaration. A hypervisor that appears on the network
  # and not in the baseline is not a host binnacle should invent — it is a
  # question for a human, which is what drift is.
  #
  # @joestump-agent 08/20/2026 - Rewrote from topology-replacement to drift.

  alias Binnacle.Fleet.Model.Site

  @type drift :: %{
          kind: :unknown_proxmox_node | :unknown_unifi_site | :missing_proxmox_node,
          detail: String.t(),
          observed: String.t(),
          site: String.t() | nil
        }

  @doc """
  Drift between a site's declared slug and the site names its controller
  reports.

  Every controller in this fleet answers "default", so a match is not
  expected and is not what this checks for. What it catches is a controller
  that has been given MORE than one site, or renamed away from the one it
  had: either means the property's network was re-organized underneath a
  declaration that still says otherwise.

  `declared` is binnacle's slug for the property; `observed` are the site
  names the controller returned.
  """
  @spec unifi_site_drift(String.t(), [Site.t() | String.t()]) :: [drift()]
  def unifi_site_drift(declared, observed) do
    names = Enum.map(observed, &site_name/1)

    case names do
      # One site is the normal shape: the controller's own "default", which
      # is not a name for anything and is never adopted as a slug.
      [_single] ->
        []

      [] ->
        [
          %{
            kind: :unknown_unifi_site,
            detail:
              "site #{declared}'s controller reports no sites at all; it answered, but has no network configured",
            observed: "",
            site: declared
          }
        ]

      many ->
        for name <- many do
          %{
            kind: :unknown_unifi_site,
            detail:
              "site #{declared}'s controller reports #{length(many)} sites (#{Enum.join(many, ", ")}); " <>
                "binnacle maps one property to one controller, so the extra sites are not represented",
            observed: name,
            site: declared
          }
        end
    end
  end

  @doc """
  Drift between the hosts declared for a site and the nodes Proxmox reports.

  A node the API names and the baseline does not is drift, never a new host:
  binnacle shows the estate somebody declared, and a hypervisor nobody
  declared is a question, not an entry.
  """
  @spec proxmox_node_drift(String.t(), [String.t()], [String.t()]) :: [drift()]
  def proxmox_node_drift(host_key, declared_keys, observed_nodes) do
    declared = MapSet.new(declared_keys)

    for node <- observed_nodes, not MapSet.member?(declared, node) do
      %{
        kind: :unknown_proxmox_node,
        detail:
          "#{host_key}'s Proxmox endpoint reports node #{inspect(node)}, which no baseline host declares",
        observed: node,
        site: nil
      }
    end
  end

  defp site_name(%Site{slug: slug}), do: slug
  defp site_name(name) when is_binary(name), do: name
  defp site_name(%{"name" => name}), do: name
  defp site_name(other), do: to_string(other)
end
