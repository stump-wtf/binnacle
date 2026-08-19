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
      assert Enum.count(config.hosts) == 5
      assert Enum.count(config.guests) == 3
      assert Enum.count(config.containers) == 6

      # Every host belongs to a configured site.
      slugs = MapSet.new(config.sites, & &1.slug)
      assert Enum.all?(config.hosts, &MapSet.member?(slugs, &1.site))

      # A passed-through device lands on its guest, not the host.
      assert Enum.any?(config.hardware[201], & &1.passthrough)
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
    test "init resolves the baseline from a cwd that is not the project root" do
      task =
        Task.async(fn ->
          File.cd!(System.tmp_dir!(), fn ->
            refute File.exists?(@baseline), "the cwd-relative path must not be what resolves"
            Fleet.init([])
          end)
        end)

      assert {:ok, state} = Task.await(task)
      assert Enum.count(state.hosts) == 5
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
      assert Enum.map(hosts, & &1.key) == ~w(ie01 pie01 ogma hud01)

      ie01 = Enum.find(hosts, &(&1.key == "ie01"))
      assert %Model.Sample{} = ie01.sample
      assert ie01.sample.cpu >= 0 and ie01.sample.cpu <= 100
      assert is_list(ie01.series.cpu)

      # ogma is the hot host: its rolled-up status must not be up.
      ogma = Enum.find(hosts, &(&1.key == "ogma"))
      refute ogma.status == :up

      # hud01 is silent: no signal, unknown status, never down.
      hud01 = Enum.find(hosts, &(&1.key == "hud01"))
      assert hud01.stale
      assert hud01.status == :unknown

      # buoy is the down host at the airbnb site.
      dtw = Enum.find(sites, &(&1.slug == "dtw"))
      assert hd(dtw.hosts).status == :down

      # Guests and containers hang off their host.
      ogma_guests = Enum.map(ogma.guests, & &1.name)
      assert "pve-services" in ogma_guests
      containers = ogma.guests |> Enum.flat_map(& &1.containers) |> Enum.map(& &1.name)
      assert "cairn" in containers and "navidrome" in containers
    end
  end
end
