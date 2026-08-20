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
               token: "binnacle@pve!fleet=00000000-0000-4000-8000-000000000001",
               poll_ms: 45_000
             }

      refute Map.has_key?(config.proxmox, "ie01")
    end

    test "composes a credential stored as separate id and secret halves" do
      config = Binnacle.Fleet.Config.load!(@baseline)

      assert config.proxmox["pve2"].token ==
               "binnacle@pve!fleet=00000000-0000-4000-8000-000000000002"
    end

    test "rejects a token that is only the secret half, naming the host" do
      error =
        assert_raise ArgumentError, fn ->
          Binnacle.Fleet.Config.new!(%{
            "sites" => [%{"slug" => "wynberg", "kind" => "home"}],
            "hosts" => [
              %{
                "key" => "lir",
                "site" => "wynberg",
                "proxmox" => %{
                  "url" => "https://lir:8006",
                  "token" => "00000000-0000-4000-8000-000000000000"
                }
              }
            ]
          })
        end

      assert error.message =~ "host lir"
      assert error.message =~ "USER@REALM!TOKENID=SECRET"
      # The startup error is read by humans and shipped to logs: it says what
      # is wrong with the credential without ever containing it.
      refute error.message =~ "00000000"
    end

    test "rejects a proxmox block with a url and no credential at all" do
      assert_raise ArgumentError, ~r/host lir.*no credential/s, fn ->
        Binnacle.Fleet.Config.new!(%{
          "sites" => [%{"slug" => "wynberg", "kind" => "home"}],
          "hosts" => [
            %{"key" => "lir", "site" => "wynberg", "proxmox" => %{"url" => "https://lir:8006"}}
          ]
        })
      end
    end

    test "rejects half of a split credential" do
      assert_raise ArgumentError, ~r/mixing credential shapes/, fn ->
        Binnacle.Fleet.Config.new!(%{
          "sites" => [%{"slug" => "wynberg", "kind" => "home"}],
          "hosts" => [
            %{
              "key" => "lir",
              "site" => "wynberg",
              "proxmox" => %{"url" => "https://lir:8006", "token_id" => "binnacle@pve!fleet"}
            }
          ]
        })
      end
    end

    test "rejects a proxmox block with no url" do
      assert_raise ArgumentError, ~r/incomplete proxmox/, fn ->
        Binnacle.Fleet.Config.new!(%{
          "sites" => [%{"slug" => "wynberg", "kind" => "home"}],
          "hosts" => [
            %{
              "key" => "pve1",
              "site" => "wynberg",
              "proxmox" => %{"token" => "binnacle@pve!fleet=aaaa-bbbb"}
            }
          ]
        })
      end
    end
  end

  describe "client hardening" do
    # A least-privilege API token — the shape Proxmox's own documentation
    # recommends — gets `{"data": null}` from an endpoint it may not read.
    # Mapping over that raised Protocol.UndefinedError inside the poller's
    # handle_info, which crashes the poller; OTP crash reports render the
    # GenServer state, and the token lives there. So this decode path was also
    # the way a credential reached the logs.
    test "a null guest list is a named poll failure, not a crash" do
      plug = probe_plug(nil, %{"cpu" => 0.1, "memory" => %{"total" => 100, "used" => 1}})

      assert {:error, reason} = Client.fetch("https://pve", "tok", plug: plug)
      assert reason =~ "no guest list"
      assert reason =~ "permission"
    end

    # `total || 1` did not guard this: 0 is truthy in Elixir, so a node
    # reporting zero total memory divided by zero and raised.
    test "a node reporting zero total memory omits the metric rather than raising" do
      plug = probe_plug([], %{"cpu" => 0.1, "memory" => %{"total" => 0, "used" => 0}})

      assert {:ok, %{sample: sample}} = Client.fetch("https://pve", "tok", plug: plug)
      assert sample.memory == nil
      assert sample.cpu == 10.0
    end
  end

  describe "the wire credential" do
    # The whole `USER@REALM!TOKENID=SECRET` string is the credential; PVE
    # answers 401 to the secret alone. This asserts the exact header value,
    # because "it authenticates" is only observable against a real node.
    test "the composed token goes on the wire verbatim as PVEAPIToken" do
      token = "homepage@pve!dashboard=00000000-0000-4000-8000-000000000000"
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})

        body =
          case conn.request_path do
            "/api2/json/nodes" ->
              pve_json(%{"data" => [%{"node" => "pve1", "status" => "online"}]})

            "/api2/json/nodes/pve1/status" ->
              pve_json(%{"data" => %{"cpu" => 0.1, "memory" => %{"total" => 100, "used" => 1}}})

            _ ->
              pve_json(%{"data" => []})
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      assert {:ok, _} = Client.fetch("https://pve", token, plug: plug)
      assert_receive {:auth, ["PVEAPIToken=" <> ^token]}
    end
  end

  describe "credential handling" do
    test "the poller's state never renders the token" do
      secret = "PVEAPIToken=root@pam!probe=s3cr3t-value"

      {:ok, pid} =
        GenServer.start_link(Poller,
          host_key: "pve1",
          base_url: "https://pve",
          token: secret,
          fetch: fn _, _, _ -> {:error, "nope"} end,
          sink: self(),
          interval_ms: 60_000
        )

      # :sys.get_state is the cheap stand-in for what an OTP crash report,
      # Logger metadata, or observer would print.
      refute inspect(:sys.get_state(pid)) =~ "s3cr3t-value"
    end

    test "the token still reaches the client that needs it" do
      secret = "PVEAPIToken=root@pam!probe=s3cr3t-value"
      test_pid = self()

      {:ok, _pid} =
        GenServer.start_link(Poller,
          host_key: "pve1",
          base_url: "https://pve",
          token: secret,
          fetch: fn _url, token, _opts ->
            send(test_pid, {:token_seen, token})
            {:error, "nope"}
          end,
          sink: self(),
          interval_ms: 60_000
        )

      assert_receive {:token_seen, ^secret}
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

  defp probe_plug(qemu_data, status_data) do
    fn conn ->
      body =
        case conn.request_path do
          "/api2/json/nodes" ->
            pve_json(%{"data" => [%{"node" => "pve1", "status" => "online"}]})

          "/api2/json/nodes/pve1/status" ->
            pve_json(%{"data" => status_data})

          "/api2/json/nodes/pve1/qemu" ->
            pve_json(%{"data" => qemu_data})

          "/api2/json/nodes/pve1/lxc" ->
            pve_json(%{"data" => []})
        end

      Plug.Conn.send_resp(conn, 200, body)
    end
  end

  defp pve_json(map), do: Jason.encode!(map)
end
