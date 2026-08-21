defmodule Binnacle.FleetTest do
  use ExUnit.Case, async: false

  alias Binnacle.Fleet
  alias Binnacle.Fleet.Config
  alias Binnacle.Fleet.Model

  @baseline "priv/fleet/baseline.json"

  describe "Config validation fails fast, naming the offender" do
    test "duplicate site slug" do
      assert_raise ArgumentError, ~r/duplicate site slug.*wynberg/, fn ->
        Config.new!(%{
          "sites" => [
            %{"slug" => "wynberg", "kind" => "home"},
            %{"slug" => "wynberg", "kind" => "home"}
          ],
          "hosts" => []
        })
      end
    end

    test "host referencing an unknown site" do
      assert_raise ArgumentError, ~r/host pve9 references unknown site "garage"/, fn ->
        Config.new!(%{
          "sites" => [%{"slug" => "cottage", "kind" => "home"}],
          "hosts" => [%{"key" => "pve9", "site" => "garage"}]
        })
      end
    end

    test "missing or invalid kind" do
      assert_raise ArgumentError, ~r/site dtw has missing or invalid kind/, fn ->
        Config.new!(%{
          "sites" => [%{"slug" => "dtw", "kind" => "boat"}],
          "hosts" => []
        })
      end
    end

    test "guest referencing an unknown host" do
      assert_raise ArgumentError, ~r/guest 101 references unknown host "pve9"/, fn ->
        Config.new!(%{
          "sites" => [%{"slug" => "cottage", "kind" => "home"}],
          "hosts" => [%{"key" => "pve1", "site" => "cottage"}],
          "guests" => [%{"vmid" => 101, "host" => "pve9", "name" => "x"}]
        })
      end
    end

    test "hardware referencing an unknown node" do
      assert_raise ArgumentError, ~r/references unknown node "ghost"/, fn ->
        Config.new!(%{
          "sites" => [%{"slug" => "cottage", "kind" => "home"}],
          "hosts" => [%{"key" => "pve1", "site" => "cottage"}],
          "hardware" => [
            %{"node" => "ghost", "name" => "nvme0", "kind" => "disk", "model" => "x"}
          ]
        })
      end
    end
  end

  describe "the shipped baseline" do
    test "loads and builds the containment spine" do
      config = Config.load!(@baseline)

      assert Enum.map(config.sites, & &1.slug) == ~w(wynberg dtw)
      assert Enum.count(config.hosts) == 12
      assert Enum.count(config.guests) == 7
      assert Enum.count(config.containers) == 5

      # Every host belongs to a configured site.
      slugs = MapSet.new(config.sites, & &1.slug)
      assert Enum.all?(config.hosts, &MapSet.member?(slugs, &1.site))

      # A passed-through device lands on its guest, not the host.
      assert Enum.any?(config.hardware["201@ogma"], & &1.passthrough)
      refute Enum.any?(config.hardware["ogma"] || [], & &1.passthrough)
    end

    test "the baseline carries no credentials" do
      refute @baseline |> File.read!() |> Jason.decode!() |> inspect() =~
               ~r/token|api[_-]?key|password/i
    end

    # A release runs with cwd=/app, where priv lives under
    # lib/binnacle-<vsn>/priv rather than ./priv. The default baseline was
    # cwd-relative, so Binnacle.Fleet booted fine here and died with :enoent in
    # the container — a crash no test saw, because every test runs from
    # server/. Driving init/1 from a foreign cwd is what pins it.
    #
    # Inside a Task so the sample interval init/1 arms dies with the process;
    # safe in this module because it is async: false, and File.cd! moves the
    # cwd for the whole VM.
    # The init/1 guard below did not cover Binnacle.Application's other caller:
    # poller_specs/1 was handed a separate literal "priv/fleet/baseline.json",
    # so the release crashed on boot again with the same :enoent, this time
    # before the supervision tree came up at all. Both call sites now resolve
    # through baseline_path/0, and this pins that.
    test "baseline_path resolves from a cwd that is not the project root" do
      task =
        Task.async(fn ->
          File.cd!(System.tmp_dir!(), fn ->
            path = Fleet.baseline_path()
            {Path.type(path), File.exists?(path), Fleet.poller_specs(path)}
          end)
        end)

      assert {:absolute, true, specs} = Task.await(task)
      assert is_list(specs)
    end

    test "baseline_path honours the BINNACLE_BASELINE override" do
      Application.put_env(:binnacle, :baseline, "/somewhere/else/baseline.json")
      on_exit(fn -> Application.delete_env(:binnacle, :baseline) end)

      assert Fleet.baseline_path() == "/somewhere/else/baseline.json"
    end

    test "init resolves the baseline from a cwd that is not the project root" do
      task =
        Task.async(fn ->
          File.cd!(System.tmp_dir!(), fn ->
            refute File.exists?(@baseline), "the cwd-relative path must not be what resolves"
            Fleet.init([])
          end)
        end)

      assert {:ok, state} = Task.await(task)
      assert Enum.count(state.hosts) == 12
    end
  end

  describe "roll-up" do
    test "a parent is as bad as its worst child" do
      assert Model.roll_up([:up, :degraded, :up]) == :degraded
      assert Model.roll_up([:up, :down]) == :down
    end

    test "unknown children never manufacture an outage" do
      assert Model.roll_up([:up, :unknown]) == :up
    end
  end

  describe "sample_status/1 — a saturated metric is not an outage" do
    # ADR-0005: "status colour must stay honest ... a monitoring gap is not an
    # outage". Neither is a full cache. lir and ogma both run ZFS, whose ARC
    # deliberately occupies most of RAM, so both sit near 90% memory — and the
    # overview rendered two healthy hypervisors as DOWN the moment real
    # readings started arriving.
    test "a metric past its danger threshold is :degraded, never :down" do
      saturated = %Model.Sample{
        at: DateTime.utc_now(),
        cpu: 99.0,
        memory: 99.0,
        disk: 99.0,
        cpu_temp: 99.0,
        hdd_temp: 99.0
      }

      assert Model.sample_status(saturated) == :degraded
    end

    test "lir's real reading — 90.4% memory on a ZFS host — is not an outage" do
      lir = %Model.Sample{at: DateTime.utc_now(), cpu: 7.5, memory: 90.4}

      assert Model.sample_status(lir) == :degraded
    end

    test "a nominal sample is :up" do
      idle = %Model.Sample{at: DateTime.utc_now(), cpu: 0.2, memory: 13.3}

      assert Model.sample_status(idle) == :up
    end

    test "only silence produces :down" do
      # Nothing a host can *report* makes it :down. :down is reserved for a
      # host that stopped answering, which the Fleet decides from consecutive
      # poll misses, not from any reading.
      for value <- [0.0, 50.0, 80.0, 95.0, 100.0] do
        sample = %Model.Sample{at: DateTime.utc_now(), cpu: value, memory: value}
        refute Model.sample_status(sample) == :down
      end
    end
  end

  describe "the running fleet" do
    # The application supervision tree already runs Binnacle.Fleet against the
    # shipped baseline; exercise that instance, not a second one.
    test "snapshot renders the spine with statuses, samples, and series" do
      sites = Fleet.snapshot()

      assert length(sites) == 2
      wynberg = Enum.find(sites, &(&1.slug == "wynberg"))

      hosts = wynberg.hosts
      host_keys = Enum.map(hosts, & &1.key)
      assert "lir" in host_keys
      assert "dagda" in host_keys
      assert "ogma" in host_keys
      assert "nyma" in host_keys
      assert "pidge" in host_keys
      assert "pie01" in host_keys
      assert "pie02" in host_keys
      assert "kitt" in host_keys
      assert "bender" in host_keys

      lir = Enum.find(hosts, &(&1.key == "lir"))
      assert %Model.Sample{} = lir.sample
      assert lir.sample.cpu >= 0 and lir.sample.cpu <= 100
      assert is_list(lir.series.cpu)

      # Status is derived from readings and children, never from a per-host
      # fixture keyed on the name. The three profiles that used to live here
      # ("ogma runs hot", "buoy is down", "hud01 is silent") named real
      # machines and asserted states binnacle had not measured.
      dtw = Enum.find(sites, &(&1.slug == "dtw"))
      assert Enum.all?(hosts ++ dtw.hosts, &(&1.status in [:up, :degraded, :down, :unknown]))
      assert Enum.all?(hosts ++ dtw.hosts, &(&1.telemetry in [:live, :unreachable, :none]))

      # Guests and containers hang off their host.
      ogma = Enum.find(hosts, &(&1.key == "ogma"))
      ogma_guests = Enum.map(ogma.guests, & &1.name)
      assert "pve-services" in ogma_guests
      assert "hud01" in ogma_guests
      containers = ogma.guests |> Enum.flat_map(& &1.containers) |> Enum.map(& &1.name)
      assert "cairn" in containers and "navidrome" in containers
    end
  end

  describe "poller_specs/0" do
    test "builds pollers from env nodes in live-discovery mode" do
      nodes = [
        %{
          "name" => "lir",
          "url" => "https://lir.stump.rocks:8006",
          "token" => "binnacle@pve!fleet=00000000-0000-4000-8000-000000000003"
        },
        %{
          "name" => "dagda",
          "url" => "https://dagda.stump.rocks:8006",
          "token" => "binnacle@pve!fleet=00000000-0000-4000-8000-000000000004"
        }
      ]

      Application.put_env(:binnacle, :proxmox_nodes, nodes)
      on_exit(fn -> Application.delete_env(:binnacle, :proxmox_nodes) end)

      specs = Fleet.poller_specs()

      assert Enum.map(specs, & &1.id) == [
               {Binnacle.Fleet.Proxmox.Poller, "lir"},
               {Binnacle.Fleet.Proxmox.Poller, "dagda"}
             ]

      lir = Enum.find(specs, &(&1.id == {Binnacle.Fleet.Proxmox.Poller, "lir"}))
      assert {Binnacle.Fleet.Proxmox.Poller, :start_link, [args]} = lir.start
      assert args[:host_key] == "lir"
      assert args[:base_url] == "https://lir.stump.rocks:8006"
      assert args[:token] == "binnacle@pve!fleet=00000000-0000-4000-8000-000000000003"
    end

    test "falls back to the baseline config when no env nodes are set" do
      Application.delete_env(:binnacle, :proxmox_nodes)

      specs = Fleet.poller_specs()

      assert is_list(specs)
    end
  end

  describe "which hosts count as having a telemetry source" do
    # The snapshot tells three silences apart, and the set of polled hosts is
    # what separates "we poll this and it went quiet" from "we have no way to
    # measure this at all". That set has to name the hosts poller_specs/0
    # actually starts pollers for, or the distinction reports the opposite of
    # the truth.
    test "a host polled from FLEET_PROXMOX_NODES reads as live, not as unmeasurable" do
      Application.put_env(:binnacle, :proxmox_nodes, [
        %{
          "name" => "lir",
          "url" => "https://lir.example:8006",
          "token" => "binnacle@pve!fleet=00000000-0000-4000-8000-000000000003"
        }
      ])

      on_exit(fn -> Application.delete_env(:binnacle, :proxmox_nodes) end)

      fleet = start_supervised!({Fleet, name: :env_telemetry_fleet, baseline: @baseline})

      lir =
        fleet
        |> GenServer.call(:snapshot)
        |> Enum.flat_map(& &1.hosts)
        |> Enum.find(&(&1.key == "lir"))

      assert lir.telemetry == :live
    end

    test "a host with no poller anywhere reads as having no telemetry source" do
      Application.delete_env(:binnacle, :proxmox_nodes)

      fleet = start_supervised!({Fleet, name: :baseline_telemetry_fleet, baseline: @baseline})

      assert fleet
             |> GenServer.call(:snapshot)
             |> Enum.flat_map(& &1.hosts)
             |> Enum.all?(&(&1.telemetry == :none))
    end
  end

  describe "config drift" do
    test "Proxmox drift is surfaced when the API reports an undeclared node" do
      fleet = start_supervised!({Fleet, name: :drift_proxmox_fleet, baseline: @baseline})

      send(fleet, {:proxmox, "lir", {:ok, %{guests: [], sample: nil, nodes: ["lir", "ghost"]}}})

      drift = GenServer.call(fleet, :drift)
      assert [entry] = drift
      assert entry.kind == :unknown_proxmox_node
      assert entry.observed == "ghost"
      assert entry.detail =~ "lir"
      assert entry.detail =~ "ghost"
    end

    test "Proxmox drift is cleared when the node stops being reported" do
      fleet = start_supervised!({Fleet, name: :drift_clear_fleet, baseline: @baseline})

      send(fleet, {:proxmox, "lir", {:ok, %{guests: [], sample: nil, nodes: ["lir", "ghost"]}}})
      assert GenServer.call(fleet, :drift) != []

      send(fleet, {:proxmox, "lir", {:ok, %{guests: [], sample: nil, nodes: ["lir"]}}})
      assert GenServer.call(fleet, :drift) == []
    end

    test "UniFi drift is surfaced when the controller reports extra sites" do
      fleet = start_supervised!({Fleet, name: :drift_unifi_fleet, baseline: @baseline})

      send(
        fleet,
        {:unifi, "dub", {:ok, %{gateway: nil, devices: [], site_names: ["default", "guest-net"]}}}
      )

      drift = GenServer.call(fleet, :drift)
      assert length(drift) == 2
      assert Enum.all?(drift, &(&1.kind == :unknown_unifi_site))
      assert Enum.all?(drift, &(&1.site == "dub"))
    end

    test "UniFi drift is surfaced when the controller reports no sites at all" do
      fleet = start_supervised!({Fleet, name: :drift_unifi_empty_fleet, baseline: @baseline})

      send(fleet, {:unifi, "dub", {:ok, %{gateway: nil, devices: [], site_names: []}}})

      assert [entry] = GenServer.call(fleet, :drift)
      assert entry.kind == :unknown_unifi_site
      assert entry.detail =~ "no sites at all"
    end

    test "UniFi drift clears when the controller settles back to one site" do
      fleet = start_supervised!({Fleet, name: :drift_unifi_clear_fleet, baseline: @baseline})

      send(
        fleet,
        {:unifi, "dub", {:ok, %{gateway: nil, devices: [], site_names: ["default", "guest-net"]}}}
      )

      assert GenServer.call(fleet, :drift) != []

      send(fleet, {:unifi, "dub", {:ok, %{gateway: nil, devices: [], site_names: ["default"]}}})

      assert GenServer.call(fleet, :drift) == []
    end

    test "a clean poll from one host does not clear another host's drift" do
      # Drift used to be one flat list cleared by testing `detail =~ host_key`.
      # `=~` is substring containment and the detail carries the OBSERVED node
      # name as well as the host key, so dagda's finding about a node called
      # "lir-old" was deleted the moment host "lir" polled cleanly.
      fleet = start_supervised!({Fleet, name: :drift_collision_fleet, baseline: @baseline})

      send(
        fleet,
        {:proxmox, "dagda", {:ok, %{guests: [], sample: nil, nodes: ["dagda", "lir-old"]}}}
      )

      assert [entry] = GenServer.call(fleet, :drift)
      assert entry.observed == "lir-old"

      send(fleet, {:proxmox, "lir", {:ok, %{guests: [], sample: nil, nodes: ["lir"]}}})

      assert [^entry] = GenServer.call(fleet, :drift),
             "lir's clean poll cleared drift that belongs to dagda"
    end

    test "a UniFi poll that could not read sites leaves the last answer standing" do
      # site_names is nil when fetch_sites failed but fetch_devices succeeded.
      # That is "not observed", not "no drift" — retracting a real finding on a
      # transient controller hiccup is worse than showing it a cycle late.
      fleet = start_supervised!({Fleet, name: :drift_unifi_nil_fleet, baseline: @baseline})

      send(
        fleet,
        {:unifi, "dub", {:ok, %{gateway: nil, devices: [], site_names: ["default", "guest-net"]}}}
      )

      before = GenServer.call(fleet, :drift)
      assert length(before) == 2

      send(fleet, {:unifi, "dub", {:ok, %{gateway: nil, devices: [], site_names: nil}}})

      assert GenServer.call(fleet, :drift) == before
    end

    test "a Proxmox poll that reports no node list leaves the last answer standing" do
      fleet = start_supervised!({Fleet, name: :drift_proxmox_nil_fleet, baseline: @baseline})

      send(fleet, {:proxmox, "lir", {:ok, %{guests: [], sample: nil, nodes: ["lir", "ghost"]}}})
      before = GenServer.call(fleet, :drift)
      assert before != []

      # No :nodes key at all — a poller that does not report them.
      send(fleet, {:proxmox, "lir", {:ok, %{guests: [], sample: nil}}})

      assert GenServer.call(fleet, :drift) == before
    end

    test "Proxmox and UniFi drift coexist without clearing each other" do
      fleet = start_supervised!({Fleet, name: :drift_mixed_fleet, baseline: @baseline})

      send(fleet, {:proxmox, "lir", {:ok, %{guests: [], sample: nil, nodes: ["lir", "ghost"]}}})

      send(
        fleet,
        {:unifi, "dub", {:ok, %{gateway: nil, devices: [], site_names: ["default", "guest-net"]}}}
      )

      drift = GenServer.call(fleet, :drift)
      assert Enum.count(drift, &(&1.kind == :unknown_proxmox_node)) == 1
      assert Enum.count(drift, &(&1.kind == :unknown_unifi_site)) == 2

      # Another clean Proxmox poll must not touch the UniFi findings.
      send(fleet, {:proxmox, "lir", {:ok, %{guests: [], sample: nil, nodes: ["lir"]}}})

      drift = GenServer.call(fleet, :drift)
      assert Enum.count(drift, &(&1.kind == :unknown_proxmox_node)) == 0
      assert Enum.count(drift, &(&1.kind == :unknown_unifi_site)) == 2
    end

    test "a node entry with no name is not reported as a node called nil" do
      fleet = start_supervised!({Fleet, name: :drift_nil_node_fleet, baseline: @baseline})

      send(fleet, {:proxmox, "lir", {:ok, %{guests: [], sample: nil, nodes: ["lir"]}}})

      assert GenServer.call(fleet, :drift) == []
    end

    test "a site with no drift reports an empty list, not a missing key" do
      fleet = start_supervised!({Fleet, name: :drift_absent_fleet, baseline: @baseline})

      snapshot = GenServer.call(fleet, :snapshot)
      assert Enum.all?(snapshot, &(&1.drift == []))
    end

    test "drift appears in the snapshot per-site" do
      fleet = start_supervised!({Fleet, name: :drift_snapshot_fleet, baseline: @baseline})

      send(fleet, {:proxmox, "lir", {:ok, %{guests: [], sample: nil, nodes: ["lir", "ghost"]}}})

      snapshot = GenServer.call(fleet, :snapshot)
      wynberg = Enum.find(snapshot, &(&1.slug == "wynberg"))
      assert wynberg.drift != []
      assert Enum.all?(wynberg.drift, &(&1.kind == :unknown_proxmox_node))
    end
  end
end
