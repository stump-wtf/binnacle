defmodule Binnacle.Fleet.ProxmoxTest do
  # SPEC-0001 REQ proxmox: config parsing, client decode, poller emission,
  # and the Fleet merge (re-parenting on migration, stale degradation).
  use ExUnit.Case, async: false

  alias Binnacle.Fleet
  alias Binnacle.Fleet.Proxmox.Client
  alias Binnacle.Fleet.Proxmox.Poller

  @baseline "test/fixtures/proxmox_baseline.json"

  # A private Fleet instance: tests must not mutate the application-wide
  # Binnacle.Fleet that the endpoint/LiveViews read.
  setup do
    fleet = start_supervised!({Fleet, name: :proxmox_test_fleet, baseline: @baseline})
    %{fleet: fleet}
  end

  describe "config" do
    test "parses optional proxmox blocks with cadence" do
      config = Binnacle.Fleet.Config.load!(@baseline)

      assert config.proxmox["pve1"] == %{
               base_url: "https://10.0.30.13:8006",
               token: "tok",
               poll_ms: 45_000
             }

      refute Map.has_key?(config.proxmox, "ie01")
    end

    test "rejects an incomplete proxmox block" do
      assert_raise ArgumentError, ~r/incomplete proxmox/, fn ->
        Binnacle.Fleet.Config.new!(%{
          "sites" => [%{"slug" => "wynberg", "kind" => "home"}],
          "hosts" => [
            %{"key" => "pve1", "site" => "wynberg", "proxmox" => %{"url" => "https://x"}}
          ]
        })
      end
    end
  end

  describe "client" do
    test "decodes node status, guests, and sample" do
      plug = fn conn ->
        body =
          case conn.request_path do
            "/api2/json/nodes" ->
              pve_json(%{"data" => [%{"node" => "pve1", "status" => "online"}]})

            "/api2/json/nodes/pve1/status" ->
              pve_json(%{
                "data" => %{
                  "cpu" => 0.42,
                  "memory" => %{"total" => 100, "used" => 75},
                  "sensors" => %{"cpu" => %{"temperature" => 61}}
                }
              })

            "/api2/json/nodes/pve1/qemu" ->
              pve_json(%{
                "data" => [%{"vmid" => 201, "name" => "pve-services", "status" => "running"}]
              })

            "/api2/json/nodes/pve1/lxc" ->
              pve_json(%{"data" => []})
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      assert {:ok, %{guests: [guest], sample: sample}} =
               Client.fetch("https://pve1.example:8006", "tok", plug: plug)

      assert guest.vmid == 201 and guest.status == :up
      assert sample.cpu == 42.0
      assert sample.memory == 75.0
      assert sample.cpu_temp == 61.0
    end

    test "unreachable host is an error, not a crash" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, "boom")
      end

      assert {:error, reason} = Client.fetch("https://pve1.example:8006", "tok", plug: plug)
      assert reason =~ "HTTP 500"
    end

    test "missing sensors omit metrics without failing" do
      plug = fn conn ->
        body =
          case conn.request_path do
            "/api2/json/nodes" -> pve_json(%{"data" => [%{"node" => "pve1"}]})
            "/api2/json/nodes/pve1/status" -> pve_json(%{"data" => %{"cpu" => 0.1}})
            path -> pve_json(%{"data" => []})
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      assert {:ok, %{sample: nil}} = Client.fetch("https://pve1.example:8006", "tok", plug: plug)
    end
  end

  describe "poller" do
    test "emits results to its sink every interval" do
      {:ok, pid} =
        Poller.start_link(
          host_key: "pve1",
          base_url: "https://pve1.example:8006",
          token: "tok",
          interval_ms: 5,
          fetch: fn _url, _token, _opts -> {:ok, %{guests: [], sample: nil, node_status: %{}}} end,
          sink: self()
        )

      assert_receive {:proxmox, "pve1", {:ok, %{guests: []}}}, 1_000
      assert_receive {:proxmox, "pve1", {:ok, %{guests: []}}}, 1_000
      GenServer.stop(pid)
    end
  end

  describe "fleet merge" do
    test "a successful poll re-parents a migrated guest without duplicating", %{fleet: fleet} do
      send(fleet, {:proxmox, "pve1", {:ok, %{guests: [], sample: nil, node_status: %{}}}})
      _ = :sys.get_state(Fleet)

      send(
        fleet,
        {:proxmox, "pve1",
         {:ok, %{guests: [guest(vmid: 301, name: "web")], sample: nil, node_status: %{}}}}
      )

      _ = :sys.get_state(Fleet)

      hosts = snapshot(fleet) |> Enum.flat_map(& &1.hosts)
      pve1 = Enum.find(hosts, &(&1.key == "pve1"))
      assert Enum.map(pve1.guests, & &1.vmid) == [301]

      # Migration: pve1 loses it, pve2 gains it.
      send(fleet, {:proxmox, "pve1", {:ok, %{guests: [], sample: nil, node_status: %{}}}})
      _ = :sys.get_state(Fleet)

      send(
        fleet,
        {:proxmox, "pve2",
         {:ok, %{guests: [guest(vmid: 301, name: "web")], sample: nil, node_status: %{}}}}
      )

      _ = :sys.get_state(Fleet)

      hosts = snapshot(fleet) |> Enum.flat_map(& &1.hosts)
      all = hosts |> Enum.flat_map(& &1.guests) |> Enum.map(& &1.vmid)
      assert Enum.frequencies(all)[301] == 1

      assert Enum.find(hosts, &(&1.key == "pve2")) |> then(& &1.guests) |> Enum.map(& &1.vmid) ==
               [301]
    end

    test "three consecutive misses mark the host down but keep last-known data", %{fleet: fleet} do
      sample = %Binnacle.Fleet.Model.Sample{
        at: DateTime.utc_now(),
        cpu: 10.0,
        memory: 20.0,
        disk: nil,
        cpu_temp: nil,
        gpu: nil,
        gpu_temp: nil,
        hdd_temp: nil
      }

      send(fleet, {:proxmox, "pve1", {:ok, %{guests: [], sample: sample, node_status: %{}}}})
      _ = :sys.get_state(Fleet)

      for _ <- 1..3 do
        send(fleet, {:proxmox, "pve1", {:error, "Proxmox unreachable: connection refused"}})
      end

      _ = :sys.get_state(Fleet)
      pve1 = snapshot(fleet) |> Enum.flat_map(& &1.hosts) |> Enum.find(&(&1.key == "pve1"))
      assert pve1.status == :down
      assert pve1.stale == true
      assert pve1.sample.cpu == 10.0

      # Other hosts are untouched by pve1's outage.
      other = snapshot(fleet) |> Enum.flat_map(& &1.hosts) |> Enum.find(&(&1.key == "ie01"))
      assert other.status in [:up, :unknown]
    end

    test "a success after misses clears the unreachable state", %{fleet: fleet} do
      for _ <- 1..3, do: send(fleet, {:proxmox, "pve1", {:error, "x"}})
      _ = :sys.get_state(Fleet)
      send(fleet, {:proxmox, "pve1", {:ok, %{guests: [], sample: nil, node_status: %{}}}})
      _ = :sys.get_state(Fleet)

      pve1 = snapshot(fleet) |> Enum.flat_map(& &1.hosts) |> Enum.find(&(&1.key == "pve1"))
      assert pve1.status != :down
    end
  end

  defp snapshot(fleet), do: GenServer.call(fleet, :snapshot)

  defp guest(vmid: vmid, name: name) do
    %Binnacle.Fleet.Model.Guest{
      vmid: vmid,
      host: "pve1",
      name: name,
      containers: [],
      hardware: [],
      status: :up
    }
  end

  defp pve_json(map), do: Jason.encode!(map)
end
