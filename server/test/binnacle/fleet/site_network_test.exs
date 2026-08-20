defmodule Binnacle.Fleet.SiteNetworkTest do
  # Governing: ADR-0002 (fleet taxonomy), SPEC-0001 REQ "UniFi Site
  # Discovery" and REQ "Discovery Does Not Invent Topology".
  use ExUnit.Case, async: false

  alias Binnacle.Fleet
  alias Binnacle.Fleet.Config
  alias Binnacle.Fleet.Model

  @baseline "test/fixtures/sites_baseline.json"

  setup do
    fleet = start_supervised!({Fleet, name: :site_network_fleet, baseline: @baseline})
    %{fleet: fleet}
  end

  defp site(fleet, slug) do
    fleet |> GenServer.call(:snapshot) |> Enum.find(&(&1.slug == slug))
  end

  describe "config" do
    test "a site carries its human name, and falls back to the slug" do
      config = Config.load!(@baseline)

      assert Enum.find(config.sites, &(&1.slug == "dub")).name == "51 Wynberg Park"
      assert Enum.find(config.sites, &(&1.slug == "cornell")).name == "cornell"
    end

    test "parses a per-site unifi gateway with its cadence" do
      config = Config.load!(@baseline)

      assert config.unifi["dub"].base_url == "https://192.168.110.1"
      assert config.unifi["dub"].credential == %{username: "ro", password: "pw"}
      assert config.unifi["dub"].poll_ms == 90_000
    end

    test "a site with no unifi block gets no entry, and no poller" do
      config = Config.load!(@baseline)

      refute Map.has_key?(config.unifi, "cornell")

      assert Enum.map(Fleet.unifi_poller_specs(@baseline), & &1.id) == [
               {Binnacle.Fleet.Unifi.Poller, "dub"}
             ]
    end

    test "rejects a unifi block with no credential, naming the site" do
      assert_raise ArgumentError, ~r/site dub.*no credential/s, fn ->
        Config.new!(%{
          "sites" => [%{"slug" => "dub", "kind" => "home", "unifi" => %{"url" => "https://x"}}],
          "hosts" => []
        })
      end
    end

    test "rejects a unifi block mixing credential shapes" do
      assert_raise ArgumentError, ~r/mixing credential shapes/, fn ->
        Config.new!(%{
          "sites" => [
            %{
              "slug" => "dub",
              "kind" => "home",
              "unifi" => %{"url" => "https://x", "username" => "u"}
            }
          ],
          "hosts" => []
        })
      end
    end
  end

  describe "a site's network state" do
    test "is nil until the gateway has been polled", %{fleet: fleet} do
      assert site(fleet, "dub").network == nil
    end

    test "a successful poll records the gateway and the inventory", %{fleet: fleet} do
      gateway = %Model.NetworkDevice{mac: "aa", name: "udr7", kind: :gateway, status: :up}
      switch = %Model.NetworkDevice{mac: "bb", name: "sw", kind: :switch, status: :up}

      send(fleet, {:unifi, "dub", {:ok, %{gateway: gateway, devices: [gateway, switch]}}})
      _ = GenServer.call(fleet, :snapshot)

      network = site(fleet, "dub").network

      assert network.reachable
      assert network.gateway.name == "udr7"
      assert length(network.devices) == 2
      assert network.at
    end

    test "a failed poll keeps the entry and records why", %{fleet: fleet} do
      # An absent network and an unreachable one look identical to a UI that
      # only checks for presence, and they mean opposite things: one is a site
      # nobody configured, the other is a site that lost its gateway.
      send(fleet, {:unifi, "dub", {:error, "connection refused"}})
      _ = GenServer.call(fleet, :snapshot)

      network = site(fleet, "dub").network

      refute network.reachable
      assert network.reason =~ "connection refused"
      assert network.devices == []
    end
  end

  describe "site status" do
    test "an unreachable gateway degrades the site even when its hosts are fine",
         %{fleet: fleet} do
      # binnacle sits inside the network, so reaching the hosts says nothing
      # about whether the property has connectivity.
      send(fleet, {:unifi, "dub", {:error, "connection refused"}})
      _ = GenServer.call(fleet, :snapshot)

      assert site(fleet, "dub").status == :down
    end

    test "a site with no hosts and no gateway is :unknown, not :up", %{fleet: fleet} do
      # Cornell Ave is a gateway and nothing else. Nothing has been measured,
      # so green would be a claim binnacle cannot support.
      assert site(fleet, "cornell").hosts == []
      assert site(fleet, "cornell").status == :unknown
    end

    test "a reachable gateway with no gateway device is degraded", %{fleet: fleet} do
      send(fleet, {:unifi, "dub", {:ok, %{gateway: nil, devices: []}}})
      _ = GenServer.call(fleet, :snapshot)

      assert site(fleet, "dub").status == :degraded
    end
  end
end
