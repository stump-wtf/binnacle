defmodule Binnacle.Fleet.HonestTelemetryTest do
  # Governing: ADR-0002 (fleet taxonomy), ADR-0005 (hardware-metrics zen
  # overview), SPEC-0001 REQ "Proxmox Discovery" ("an unreachable host MUST be
  # surfaced as degraded ... never silently dropped").
  #
  # The regression these cover: hosts with no telemetry source were fed
  # `Binnacle.Fleet.Sampler` — drifting sine waves with a per-host phase
  # offset. On the deployed fleet that rendered real machines binnacle could
  # not see as UP, with CPU, memory and temperature readings it had invented,
  # complete with trend lines. Silence must read as silence.
  use ExUnit.Case, async: false

  alias Binnacle.Fleet

  @baseline "test/fixtures/proxmox_baseline.json"

  setup do
    # Production's setting, restored after the test: the suite as a whole runs
    # with synthetic readings on so the meters and sparklines have data.
    previous = Application.get_env(:binnacle, :synthetic_metrics)
    Application.put_env(:binnacle, :synthetic_metrics, false)
    on_exit(fn -> Application.put_env(:binnacle, :synthetic_metrics, previous) end)

    fleet = start_supervised!({Fleet, name: :honest_test_fleet, baseline: @baseline})
    %{fleet: fleet}
  end

  defp host(fleet, key) do
    fleet
    |> GenServer.call(:snapshot)
    |> Enum.flat_map(& &1.hosts)
    |> Enum.find(&(&1.key == key))
  end

  describe "a host with no telemetry source" do
    test "reports no readings rather than invented ones", %{fleet: fleet} do
      ie01 = host(fleet, "ie01")

      assert ie01.sample == nil
      assert Enum.all?(ie01.series.cpu, &is_nil/1)
      assert Enum.all?(ie01.series.cpu_temp, &is_nil/1)
    end

    test "is :unknown, not :up and not :down", %{fleet: fleet} do
      # :up would claim a health check that never ran; :down would page
      # someone about a machine that is very likely fine.
      assert host(fleet, "ie01").status == :unknown
    end

    test "is distinguishable from an unreachable host", %{fleet: fleet} do
      assert host(fleet, "ie01").telemetry == :none
      assert host(fleet, "ie01").stale

      # pve1 is polled: before any poll result lands it is a live source with
      # nothing yet, never :none.
      assert host(fleet, "pve1").telemetry in [:live, :unreachable]
    end
  end

  describe "a polled host that stops answering" do
    test "is :down and marked unreachable after three consecutive misses", %{fleet: fleet} do
      for _ <- 1..3, do: send(fleet, {:proxmox, "pve1", {:error, "connection refused"}})
      _ = GenServer.call(fleet, :snapshot)

      pve1 = host(fleet, "pve1")

      assert pve1.status == :down
      assert pve1.telemetry == :unreachable
      assert pve1.stale
    end

    test "the first two misses do not flip it", %{fleet: fleet} do
      for _ <- 1..2, do: send(fleet, {:proxmox, "pve1", {:error, "connection refused"}})
      _ = GenServer.call(fleet, :snapshot)

      refute host(fleet, "pve1").telemetry == :unreachable
    end
  end

  describe "synthetic readings" do
    test "are off unless explicitly enabled", %{fleet: fleet} do
      # Not a fallback that quietly engages when discovery is unconfigured:
      # a fixture, and only where a fixture is wanted.
      assert host(fleet, "ie01").sample == nil

      Application.put_env(:binnacle, :synthetic_metrics, true)
      send(fleet, :tick)
      _ = GenServer.call(fleet, :snapshot)

      assert host(fleet, "ie01").sample != nil
    end
  end
end
