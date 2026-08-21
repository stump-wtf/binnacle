defmodule Binnacle.Fleet.Proxmox.DiskPoller do
  # One disk-health poller per Proxmox host (issue #69). Follows the same
  # pattern as the main Poller: emits messages, never touches shared state.
  # Runs at a slower cadence (60s default) because SMART queries are
  # per-disk and take longer than the status/guest poll.
  #
  # The poller is also where per-disk deltas come from. `UDMA_CRC_Error_Count`
  # and `Command_Timeout` are lifetime counters, so their absolute values are
  # useless as an alert: a drive carrying scars from a cable replaced two years
  # ago would alert forever, and a fleet where everything alerts is a fleet
  # nobody looks at. What matters is whether a counter moved *since the last
  # poll*. That needs the previous reading, and this process is the only place
  # that has one — Binnacle.Fleet sees a single snapshot at a time.
  #
  # Readings are keyed by serial where the drive has one and by device path
  # otherwise, because /dev/sdX is assigned at discovery and a reboot can
  # renumber the bus. Keying on the path alone would compare one drive's
  # counter against another drive's and invent a delta out of nothing.
  #
  # @joestump-agent 08/21/2026 - Initial version for issue #69.
  #
  # @joestump 08/21/2026 - Added the delta tracking while reviewing #71. The
  #   model and the docs already described it as the alert rule, but nothing
  #   ever wrote :crc_delta or :cmd_delta, so the branch reading them in
  #   Model.disk_status/1 could not fire — and a link degrading is the exact
  #   failure that motivated the issue.

  use GenServer

  alias Binnacle.Fleet.Proxmox.Client
  alias Binnacle.Fleet.Proxmox.Token

  @default_interval :timer.seconds(60)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: keyword_name(opts))
  end

  defp keyword_name(opts), do: Keyword.get(opts, :name)

  @impl true
  def init(opts) do
    Process.flag(:sensitive, true)

    host_key = Keyword.fetch!(opts, :host_key)
    base_url = Keyword.fetch!(opts, :base_url)
    token = Token.new(Keyword.fetch!(opts, :token))
    interval = Keyword.get(opts, :interval_ms, @default_interval)
    fetch_disks = Keyword.get(opts, :fetch_disks, &Client.fetch_disks/3)
    fetch_pools = Keyword.get(opts, :fetch_pools, &Client.fetch_pools/3)
    fetch_opts = Keyword.get(opts, :fetch_opts, [])
    sink = Keyword.get(opts, :sink, Binnacle.Fleet)

    state = %{
      host_key: host_key,
      base_url: base_url,
      token: token,
      interval_ms: interval,
      fetch_disks: fetch_disks,
      fetch_pools: fetch_pools,
      fetch_opts: fetch_opts,
      sink: sink,
      previous: %{}
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    token = Token.reveal(state.token)

    disks = state.fetch_disks.(state.base_url, token, state.fetch_opts)
    pools = state.fetch_pools.(state.base_url, token, state.fetch_opts)

    {disks, previous} = apply_deltas(disks, state.previous)

    send(state.sink, {:disk_health, state.host_key, %{disks: disks, pools: pools}})
    {:noreply, %{state | previous: previous}, {:continue, :reschedule}}
  end

  # Stamp each disk with how far its link-error counters moved since the last
  # poll, and remember this poll's readings for the next one.
  #
  # A disk seen for the first time gets a delta of 0, not its lifetime total:
  # the first poll establishes the baseline, it does not indict the drive for
  # its history. A failed fetch leaves `previous` untouched, so the next
  # successful poll measures against the last reading that actually happened
  # rather than against nothing.
  defp apply_deltas({:ok, disks}, previous) when is_list(disks) do
    stamped =
      Enum.map(disks, fn disk ->
        was = Map.get(previous, disk_id(disk))

        attrs =
          (disk.attributes || %{})
          |> Map.put(:crc_delta, delta(was, disk.attributes, :crc_errors))
          |> Map.put(:cmd_delta, delta(was, disk.attributes, :command_timeout))

        %{disk | attributes: attrs}
      end)

    {{:ok, stamped}, Map.new(stamped, &{disk_id(&1), &1.attributes})}
  end

  defp apply_deltas(other, previous), do: {other, previous}

  # nil `was` is a first sighting; nil counters are a drive that does not
  # report that attribute at all. Neither is movement, so both are 0. A
  # counter that goes *down* (a drive replaced in the same bay, a firmware
  # reset) is clamped to 0 rather than reported as a negative delta.
  defp delta(nil, _now, _key), do: 0

  defp delta(was, now, key) do
    case {was[key], (now || %{})[key]} do
      {before, current} when is_integer(before) and is_integer(current) ->
        max(current - before, 0)

      _ ->
        0
    end
  end

  # Serial where the drive has one; device path otherwise. /dev/sdX is
  # assigned at discovery and a reboot can renumber the bus, so the path alone
  # would compare one drive's counter against another's.
  defp disk_id(%{serial: serial}) when is_binary(serial) and serial != "", do: {:serial, serial}
  defp disk_id(%{device: device}), do: {:device, device}

  @impl true
  def handle_continue(:reschedule, state) do
    Process.send_after(self(), :poll, state.interval_ms)
    {:noreply, state}
  end
end
