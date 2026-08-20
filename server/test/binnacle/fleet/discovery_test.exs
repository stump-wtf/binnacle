defmodule Binnacle.Fleet.DiscoveryTest do
  # Governing: ADR-0002 (fleet taxonomy), SPEC-0001 REQ "Discovery Does Not
  # Invent Topology" and REQ "UniFi Site Discovery".
  #
  # The regression these lock down: Discovery used to BUILD a topology from
  # the APIs, which Binnacle.Fleet then adopted wholesale. Hosts came only
  # from the Proxmox node lists (so every standalone Docker host disappeared)
  # and sites came from UniFi (so all four properties collapsed into one
  # called "default", because that is what every controller reports).
  #
  # Topology is declared. Discovery reports disagreement.
  use ExUnit.Case, async: true

  alias Binnacle.Fleet.Discovery

  describe "the module cannot construct topology" do
    test "it exposes no way to produce sites or hosts" do
      exported = Discovery.__info__(:functions) |> Keyword.keys() |> Enum.uniq()

      refute :discover in exported
      assert Enum.sort(exported) == [:proxmox_node_drift, :unifi_site_drift]
    end
  end

  describe "unifi_site_drift/2" do
    test "one site is the normal shape and is not drift" do
      # Every controller in this fleet answers with its own single site,
      # named "default". That name is not adopted as a slug and its presence
      # is not a finding.
      assert Discovery.unifi_site_drift("dub", ["default"]) == []
    end

    test "a controller reporting several sites is drift, one entry each" do
      drift = Discovery.unifi_site_drift("dtw", ["default", "guest-net"])

      assert length(drift) == 2
      assert Enum.all?(drift, &(&1.kind == :unknown_unifi_site))
      assert Enum.all?(drift, &(&1.site == "dtw"))
      assert Enum.sort(Enum.map(drift, & &1.observed)) == ["default", "guest-net"]
    end

    test "the drift names the site and what was observed" do
      [first | _] = Discovery.unifi_site_drift("dtw", ["default", "guest-net"])

      assert first.detail =~ "dtw"
      assert first.detail =~ "2 sites"
      assert first.detail =~ "guest-net"
    end

    test "a controller reporting no sites at all is drift" do
      assert [drift] = Discovery.unifi_site_drift("cornell", [])

      assert drift.kind == :unknown_unifi_site
      assert drift.detail =~ "no sites at all"
      assert drift.site == "cornell"
    end

    test "accepts site structs and raw API maps, not just names" do
      alias Binnacle.Fleet.Model.Site

      assert Discovery.unifi_site_drift("dub", [%Site{slug: "default"}]) == []
      assert Discovery.unifi_site_drift("dub", [%{"name" => "default"}]) == []
    end
  end

  describe "proxmox_node_drift/3" do
    test "a declared node is not drift" do
      assert Discovery.proxmox_node_drift("lir", ["lir", "dagda"], ["lir"]) == []
    end

    test "a node no baseline host declares is drift, never a new host" do
      assert [drift] = Discovery.proxmox_node_drift("lir", ["lir", "dagda"], ["lir", "ghost"])

      assert drift.kind == :unknown_proxmox_node
      assert drift.observed == "ghost"
      assert drift.detail =~ "lir"
      assert drift.detail =~ "ghost"
      assert drift.detail =~ "no baseline host declares"
    end

    test "reports every undeclared node, not just the first" do
      drift = Discovery.proxmox_node_drift("lir", ["lir"], ["lir", "ghost", "phantom"])

      assert Enum.map(drift, & &1.observed) == ["ghost", "phantom"]
    end
  end
end
