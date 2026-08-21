defmodule Binnacle.Fleet.Proxmox.DiskPollerTest do
  # The delta rule is the whole point of the link-error alert, and it is the
  # one thing the absolute counters cannot express. `UDMA_CRC_Error_Count` is
  # a lifetime total: a drive whose cable was replaced two years ago still
  # carries the scars, so alerting on `> 0` alerts forever and trains everyone
  # to ignore it. Alerting on movement catches the link that is degrading now.
  #
  # @joestump 08/21/2026 - Added while reviewing #71, alongside the delta
  #   tracking itself. Model.disk_status/1 and the Disk moduledoc both already
  #   described this rule; nothing wrote :crc_delta or :cmd_delta, so the
  #   branch reading them was unreachable.

  use ExUnit.Case, async: true

  alias Binnacle.Fleet.Model
  alias Binnacle.Fleet.Model.Disk
  alias Binnacle.Fleet.Proxmox.DiskPoller

  defp disk(serial, crc, cmd) do
    %Disk{
      device: "/dev/sda",
      serial: serial,
      health: :passed,
      temperature: 35.0,
      attributes: %{
        pending: 0,
        uncorrectable: 0,
        crc_errors: crc,
        command_timeout: cmd,
        reallocated: 0,
        power_on_hours: 30_000
      }
    }
  end

  # Drives the poller through real polls rather than calling private helpers:
  # the delta only exists because the process remembers the last reading, and
  # a test that bypassed the process would not prove that.
  defp poll_sequence(responses) do
    owner = self()
    {:ok, agent} = Agent.start_link(fn -> responses end)

    # The poller keeps ticking after the responses run out; hold the last one
    # rather than crashing the fetch, so a slow assertion cannot fail the test
    # for a reason that has nothing to do with deltas.
    fetch = fn _url, _token, _opts ->
      Agent.get_and_update(agent, fn
        [only] -> {only, [only]}
        [head | rest] -> {head, rest}
      end)
    end

    {:ok, poller} =
      DiskPoller.start_link(
        name: nil,
        host_key: "lir",
        base_url: "https://pve",
        token: "tok",
        interval_ms: 50,
        fetch_disks: fetch,
        fetch_pools: fn _, _, _ -> {:ok, []} end,
        sink: owner
      )

    results =
      for _ <- responses do
        assert_receive {:disk_health, "lir", %{disks: {:ok, disks}}}, 2_000
        disks
      end

    GenServer.stop(poller)
    results
  end

  test "the first sighting of a drive is a baseline, not an indictment" do
    [[first]] = poll_sequence([{:ok, [disk("Z001", 4127, 12)]}])

    assert first.attributes[:crc_delta] == 0
    assert first.attributes[:cmd_delta] == 0
    assert Model.disk_status(first) == :up
  end

  test "a link that degrades between polls goes degraded" do
    [_baseline, [second]] =
      poll_sequence([
        {:ok, [disk("Z001", 4127, 12)]},
        {:ok, [disk("Z001", 4139, 12)]}
      ])

    assert second.attributes[:crc_delta] == 12
    assert Model.disk_status(second) == :degraded
  end

  test "a high but static counter stays up — old scars are not an alert" do
    [_baseline, [second]] =
      poll_sequence([
        {:ok, [disk("Z001", 4127, 12)]},
        {:ok, [disk("Z001", 4127, 12)]}
      ])

    assert second.attributes[:crc_delta] == 0
    assert Model.disk_status(second) == :up
  end

  test "command timeouts move the needle on their own" do
    [_baseline, [second]] =
      poll_sequence([
        {:ok, [disk("Z001", 0, 3)]},
        {:ok, [disk("Z001", 0, 5)]}
      ])

    assert second.attributes[:cmd_delta] == 2
    assert Model.disk_status(second) == :degraded
  end

  test "a counter that goes backwards is clamped, not reported negative" do
    # A drive swapped into the same bay, or a firmware counter reset. Reporting
    # a negative delta would be meaningless; reporting movement would be a lie.
    [_baseline, [second]] =
      poll_sequence([
        {:ok, [disk("Z001", 900, 0)]},
        {:ok, [disk("Z001", 2, 0)]}
      ])

    assert second.attributes[:crc_delta] == 0
    assert Model.disk_status(second) == :up
  end

  test "readings are keyed by serial, so a renumbered bus does not invent a delta" do
    # Both polls report the same two drives; the second poll has them on
    # swapped device paths, as happens across a reboot. Keying on /dev/sdX
    # would compare Z001's counter against Z002's and fabricate movement.
    a = %{disk("Z001", 100, 0) | device: "/dev/sda"}
    b = %{disk("Z002", 900, 0) | device: "/dev/sdb"}
    a_moved = %{disk("Z001", 100, 0) | device: "/dev/sdb"}
    b_moved = %{disk("Z002", 900, 0) | device: "/dev/sda"}

    [_baseline, second] = poll_sequence([{:ok, [a, b]}, {:ok, [a_moved, b_moved]}])

    assert Enum.all?(second, &(&1.attributes[:crc_delta] == 0))
    assert Enum.all?(second, &(Model.disk_status(&1) == :up))
  end

  test "a failed fetch leaves the baseline alone rather than resetting it" do
    [_baseline, _failure, [third]] =
      poll_sequence([
        {:ok, [disk("Z001", 4127, 0)]},
        {:error, "Proxmox unreachable"},
        {:ok, [disk("Z001", 4127, 0)]}
      ])
      |> then(fn [a, b, c] -> [a, b, c] end)

    assert third.attributes[:crc_delta] == 0
  end
end
