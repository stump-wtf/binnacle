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

      # ogma is the hot host: its rolled-up status must not be up.
      ogma = Enum.find(hosts, &(&1.key == "ogma"))
      refute ogma.status == :up

      # buoy is the down host at the airbnb site.
      dtw = Enum.find(sites, &(&1.slug == "dtw"))
      buoy = Enum.find(dtw.hosts, &(&1.key == "buoy"))
      assert buoy.status == :down

      # Guests and containers hang off their host.
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
        %{"name" => "lir", "url" => "https://lir.stump.rocks:8006", "token" => "tok-lir"},
        %{"name" => "dagda", "url" => "https://dagda.stump.rocks:8006", "token" => "tok-dagda"}
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
      assert args[:token] == "tok-lir"
    end

    test "falls back to the baseline config when no env nodes are set" do
      Application.delete_env(:binnacle, :proxmox_nodes)

      specs = Fleet.poller_specs()

      assert is_list(specs)
    end
  end
end
