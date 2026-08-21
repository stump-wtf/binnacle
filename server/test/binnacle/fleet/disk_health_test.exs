defmodule Binnacle.Fleet.DiskHealthTest do
  # Issue #69: SMART, drive temperature, ZFS pool state, and SATA link
  # errors collected from hypervisors via the Proxmox API.
  use ExUnit.Case, async: false

  alias Binnacle.Fleet.Model
  alias Binnacle.Fleet.Model.{Disk, ZfsPool}
  alias Binnacle.Fleet.Proxmox.Client

  describe "Disk model" do
    test "disk_status/1 returns :down for failed SMART" do
      disk = %Disk{health: :failed}
      assert Model.disk_status(disk) == :down
    end

    test "disk_status/1 returns :unknown for unknown SMART" do
      disk = %Disk{health: :unknown}
      assert Model.disk_status(disk) == :unknown
    end

    test "disk_status/1 returns :degraded when pending sectors > 0" do
      disk = %Disk{health: :passed, attributes: %{pending: 1}}
      assert Model.disk_status(disk) == :degraded
    end

    test "disk_status/1 returns :degraded when uncorrectable > 0" do
      disk = %Disk{health: :passed, attributes: %{uncorrectable: 1}}
      assert Model.disk_status(disk) == :degraded
    end

    test "disk_status/1 returns :up when healthy with zero attributes" do
      disk = %Disk{health: :passed, attributes: %{}}
      assert Model.disk_status(disk) == :up
    end

    test "disk_status/1 returns :degraded when temperature > 50" do
      disk = %Disk{health: :passed, temperature: 55.0, attributes: %{}}
      assert Model.disk_status(disk) == :degraded
    end

    test "disk_status/1 returns :up when temperature is normal" do
      disk = %Disk{health: :passed, temperature: 35.0, attributes: %{}}
      assert Model.disk_status(disk) == :up
    end
  end

  describe "ZfsPool model" do
    test "pool_status/1 returns :down for faulted pool" do
      pool = %ZfsPool{state: :faulted}
      assert Model.pool_status(pool) == :down
    end

    test "pool_status/1 returns :down for suspended pool" do
      pool = %ZfsPool{state: :suspended}
      assert Model.pool_status(pool) == :down
    end

    test "pool_status/1 returns :degraded for degraded pool" do
      pool = %ZfsPool{state: :degraded}
      assert Model.pool_status(pool) == :degraded
    end

    test "pool_status/1 returns :degraded when vdevs have errors" do
      pool = %ZfsPool{
        state: :online,
        vdevs: [%{read: 0, write: 1, cksum: 0}]
      }

      assert Model.pool_status(pool) == :degraded
    end

    test "pool_status/1 returns :up for healthy pool" do
      pool = %ZfsPool{state: :online, vdevs: []}
      assert Model.pool_status(pool) == :up
    end
  end

  describe "Client.fetch_disks/3" do
    test "parses disk list with SMART health" do
      plug = disk_plug()

      assert {:ok, disks} = Client.fetch_disks("https://pve", "tok", plug: plug)
      assert length(disks) == 2

      [sda, sdb] = disks

      assert sda.device == "/dev/sda"
      assert sda.model == "ST4000DM000-1F2168"
      assert sda.serial == "Z0001"
      assert sda.health == :passed
      assert sda.temperature == 35.0
      assert sda.attributes[:reallocated] == 0
      assert sda.attributes[:pending] == 0
      assert sda.attributes[:uncorrectable] == 0
      assert sda.attributes[:crc_errors] == 0

      assert sdb.device == "/dev/sdb"
      assert sdb.health == :failed
    end

    test "returns empty list when host has no disks" do
      plug = fn conn ->
        case conn.request_path do
          "/api2/json/nodes" ->
            Plug.Conn.send_resp(
              conn,
              200,
              pve_json(%{"data" => [%{"node" => "pve1", "status" => "online"}]})
            )

          "/api2/json/nodes/pve1/disks/list" ->
            Plug.Conn.send_resp(conn, 200, pve_json(%{"data" => []}))

          _ ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end

      assert {:ok, disks} = Client.fetch_disks("https://pve", "tok", plug: plug)
      assert disks == []
    end
  end

  describe "Client.fetch_pools/3" do
    test "parses ZFS pool list" do
      plug = pool_plug()

      assert {:ok, pools} = Client.fetch_pools("https://pve", "tok", plug: plug)
      assert length(pools) == 1

      [pool] = pools

      assert pool.name == "tank"
      assert pool.state == :online
      assert pool.size == 10_000_000_000_000
      assert pool.allocated == 3_000_000_000_000
    end

    test "returns empty list when host has no ZFS pools" do
      plug = fn conn ->
        case conn.request_path do
          "/api2/json/nodes" ->
            Plug.Conn.send_resp(
              conn,
              200,
              pve_json(%{"data" => [%{"node" => "pve1", "status" => "online"}]})
            )

          "/api2/json/nodes/pve1/disks/zfs" ->
            Plug.Conn.send_resp(conn, 200, pve_json(%{"data" => []}))

          _ ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end

      assert {:ok, pools} = Client.fetch_pools("https://pve", "tok", plug: plug)
      assert pools == []
    end
  end

  # ---- test helpers ----

  defp disk_plug do
    fn conn ->
      body =
        case conn.request_path do
          "/api2/json/nodes" ->
            pve_json(%{"data" => [%{"node" => "pve1", "status" => "online"}]})

          "/api2/json/nodes/pve1/disks/list" ->
            pve_json(%{
              "data" => [
                %{
                  "devpath" => "/dev/sda",
                  "model" => "ST4000DM000-1F2168",
                  "serial" => "Z0001",
                  "size" => 4_000_000_000_000,
                  "type" => "hdd",
                  "health" => "PASSED",
                  "wearout" => "N/A"
                },
                %{
                  "devpath" => "/dev/sdb",
                  "model" => "ST4000DM000-1F2168",
                  "serial" => "Z0002",
                  "size" => 4_000_000_000_000,
                  "type" => "hdd",
                  "health" => "FAILED",
                  "wearout" => "N/A"
                }
              ]
            })

          path ->
            disk = conn.query_string |> URI.decode_query() |> Map.get("disk", "")
            IO.puts("SMART disk: #{disk}")

            cond do
              String.contains?(disk, "sda") ->
                pve_json(%{
                  "data" => %{
                    "health" => "PASSED",
                    "type" => "ata",
                    "attributes" => [
                      %{"name" => "Reallocated_Sector_Ct", "raw" => "0"},
                      %{"name" => "Current_Pending_Sector", "raw" => "0"},
                      %{"name" => "Offline_Uncorrectable", "raw" => "0"},
                      %{"name" => "UDMA_CRC_Error_Count", "raw" => "0"},
                      %{"name" => "Command_Timeout", "raw" => "0"},
                      %{"name" => "Power_On_Hours", "raw" => "30000"},
                      %{"name" => "Temperature_Celsius", "raw" => "35"}
                    ]
                  }
                })

              String.contains?(disk, "sdb") ->
                pve_json(%{
                  "data" => %{
                    "health" => "FAILED",
                    "type" => "ata",
                    "attributes" => [
                      %{"name" => "Reallocated_Sector_Ct", "raw" => "13"},
                      %{"name" => "Current_Pending_Sector", "raw" => "100"},
                      %{"name" => "Temperature_Celsius", "raw" => "42"}
                    ]
                  }
                })

              true ->
                ""
            end
        end

      Plug.Conn.send_resp(conn, 200, body)
    end
  end

  defp pool_plug do
    fn conn ->
      body =
        case conn.request_path do
          "/api2/json/nodes" ->
            pve_json(%{"data" => [%{"node" => "pve1", "status" => "online"}]})

          "/api2/json/nodes/pve1/disks/zfs" ->
            pve_json(%{
              "data" => [
                %{
                  "name" => "tank",
                  "size" => 10_000_000_000_000,
                  "alloc" => 3_000_000_000_000,
                  "free" => 7_000_000_000_000,
                  "frag" => 23,
                  "health" => "ONLINE"
                }
              ]
            })
        end

      Plug.Conn.send_resp(conn, 200, body)
    end
  end

  defp pve_json(map), do: Jason.encode!(map)
end
